import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers.dart';
import '../../../core/clock.dart';
import '../../../data/sqlite/app_database.dart';
import '../../../domain/entities/transaction.dart';
import '../../../application/quick_entry/quick_entry_memory.dart';
import 'amount_keypad.dart';

/// 快記狀態機階段（SDD §5.1）。
enum QuickEntryPhase {
  ready,
  inputting,
  committing,
  savedDialog,
}

/// 快記模式（PM 2026-10-24 定稿：**僅 支出／收入／轉帳**）。
///
/// 「拆分」移至**明細→編輯交易**（FR-T6；入口另開任務）；「預算」設定回**預算頁**表單
/// （預算頁本有新增/編輯表單，快記不再兼作預算輸入）。
enum QuickEntryMode { expense, income, transfer }

/// 快記狀態（SDD §5.1；Sticky 欄位＝帳戶/分類/商家，金額/時間每筆重設）。
class QuickEntryState {
  const QuickEntryState({
    required this.phase,
    this.mode = QuickEntryMode.expense,
    this.account,
    this.toAccount,
    this.category,
    this.merchant = '',
    this.note = '',
    this.amount = '',
    required this.occurredAt,
    this.sessionCount = 0,
    this.lastSaveMs,
  });

  final QuickEntryPhase phase;

  /// 記帳模式（F02 S2.3：轉帳不適用分類/商家，UI 隱藏之）。
  final QuickEntryMode mode;
  final AccountRow? account;

  /// 轉帳目標帳戶（transfer 專用；BE 驗證須相異）。
  final AccountRow? toAccount;

  final CategoryRow? category;
  final String merchant;

  /// 備註（PM 2026-10-24：手機與 PC 皆有；選填）。
  final String note;

  /// 金額欄文字（數字鍵盤輸入；入庫時轉 minor units）。
  final String amount;
  final DateTime occurredAt;

  /// 本次連記筆數（FR-Q2「本次已記 N 筆」）。
  final int sessionCount;

  /// 純入庫耗時（NFR-01 UI 計時，S1.6；不含對話框動畫）。
  final int? lastSaveMs;

  QuickEntryState copyWith({
    QuickEntryPhase? phase,
    QuickEntryMode? mode,
    AccountRow? account,
    AccountRow? toAccount,
    bool clearToAccount = false,
    CategoryRow? category,
    bool clearCategory = false,
    String? merchant,
    String? note,
    String? amount,
    DateTime? occurredAt,
    int? sessionCount,
    int? lastSaveMs,
  }) =>
      QuickEntryState(
        phase: phase ?? this.phase,
        mode: mode ?? this.mode,
        account: account ?? this.account,
        toAccount: clearToAccount ? null : (toAccount ?? this.toAccount),
        category: clearCategory ? null : (category ?? this.category),
        merchant: merchant ?? this.merchant,
        note: note ?? this.note,
        amount: amount ?? this.amount,
        occurredAt: occurredAt ?? this.occurredAt,
        sessionCount: sessionCount ?? this.sessionCount,
        lastSaveMs: lastSaveMs ?? this.lastSaveMs,
      );
}

/// 快記 controller（FR-Q2~Q5；SDD §5.1 狀態機）。
///
/// autoDispose：離開快記頁即銷毀——「離開快記頁後不再提供復原入口」的
/// 生命週期由本 provider 的存活範圍表達（FR-Q2/Q3，acceptance S1.8-4）。
class QuickEntryController extends AutoDisposeNotifier<QuickEntryState> {
  @override
  QuickEntryState build() {
    // FR-Q4／SDD §5.1 系統預填：帳戶＋分類（智慧/固定預設）＋時間=現在。
    final preset = ref.watch(quickEntryPresetProvider).compute();
    return QuickEntryState(
      phase: QuickEntryPhase.ready,
      account: preset.account,
      category: preset.category,
      occurredAt: preset.time,
    );
  }

  /// 目前模式之分類種類（支出／收入；轉帳不適用分類）。
  String get _catKind =>
      state.mode == QuickEntryMode.income ? 'income' : 'expense';

  /// 目前模式之分類清單。
  List<CategoryRow> get _categories =>
      ref.read(dbProvider).categoriesByKind(_catKind);

  // ── 欄位輸入（Inputting） ─────────────────────────────────

  void setAmount(String text) =>
      state = state.copyWith(amount: text, phase: QuickEntryPhase.inputting);

  void setMerchant(String text) =>
      state = state.copyWith(merchant: text, phase: QuickEntryPhase.inputting);

  /// 備註（PM 2026-10-24）。
  void setNote(String text) =>
      state = state.copyWith(note: text, phase: QuickEntryPhase.inputting);

  void setOccurredAt(DateTime t) =>
      state = state.copyWith(occurredAt: t, phase: QuickEntryPhase.inputting);

  void selectAccountById(String? id) {
    if (id == null) return;
    for (final a in ref.read(activeAccountsProvider)) {
      if (a.id == id) {
        state = state.copyWith(account: a, phase: QuickEntryPhase.inputting);
        return;
      }
    }
  }

  void selectCategoryById(String? id) {
    if (id == null) return;
    for (final c in _categories) {
      if (c.id == id) {
        var next =
            state.copyWith(category: c, phase: QuickEntryPhase.inputting);
        // **帶入守衛**（T72，PM 2026-11-24）：金額已輸入（非 0/空）→
        // 變更分類**不帶入上次資料**（金額/帳戶/商家皆不動——避免蓋掉
        // 使用者已輸入的金額）；金額為 0/空 → 照舊帶入。
        final entered =
            int.tryParse(state.amount.replaceAll(',', '')) ?? 0;
        if (entered <= 0) {
          // 「記住上次」（PM 2026-10-24）：帶入該分類上次的**金額/帳戶/商家**
          // （日期仍為現在）；無紀錄或空值 → 沿用 Sticky（上一筆）值。
          final mem = ref.read(quickEntryMemoryProvider).load(c.id);
          if (mem != null) {
            if (mem.amount.isNotEmpty) next = next.copyWith(amount: mem.amount);
            if (mem.merchant.isNotEmpty) {
              next = next.copyWith(merchant: mem.merchant);
            }
            if (mem.accountId != null) {
              for (final a in ref.read(activeAccountsProvider)) {
                if (a.id == mem.accountId) {
                  next = next.copyWith(account: a);
                  break;
                }
              }
            }
          }
          // 「子類別帶入」（PM 2026-11-21）：同分類**最後一筆交易**的商家/金額
          // 為最新事實（涵蓋掃描/匯入等非快記入帳——記憶只記快記流程），
          // 覆蓋記憶值；商家 null → 不清空既有值。
          final tx = ref.read(dbProvider).latestTransactionByCategory(c.id);
          if (tx != null) {
            next = next.copyWith(amount: '${tx.amountMinor}');
            if (tx.merchant != null) {
              next = next.copyWith(merchant: tx.merchant!);
            }
          }
        }
        state = next;
        return;
      }
    }
  }

  /// 依名稱選帳戶（BDD 綁定用；不存在拋錯）。
  void selectAccount(String name) {
    for (final a in ref.read(activeAccountsProvider)) {
      if (a.name == name) {
        state = state.copyWith(account: a, phase: QuickEntryPhase.inputting);
        return;
      }
    }
    throw StateError('帳戶不存在：$name');
  }

  /// 依名稱選分類（BDD 綁定用；不存在拋錯）。
  void selectCategory(String name) {
    for (final c in ref.read(expenseCategoriesProvider)) {
      if (c.name == name) {
        state = state.copyWith(category: c, phase: QuickEntryPhase.inputting);
        return;
      }
    }
    throw StateError('分類不存在：$name');
  }

  // ── 模式與目標帳戶（F02 S2.3 轉帳） ──────────────────────

  /// 切換模式（支出／收入／轉帳；PM 2026-10-24）。
  /// 轉帳不適用分類/商家（BE 強制 null，UI 隱藏）；收入↔支出之分類集不同
  /// → 切換時重選該類別集首項（無則清空）。
  void setMode(QuickEntryMode mode) {
    if (mode == state.mode) return;
    state = state.copyWith(
        mode: mode, clearToAccount: true, clearCategory: true);
    if (mode != QuickEntryMode.transfer) {
      final cats = _categories;
      if (cats.isNotEmpty) state = state.copyWith(category: cats.first);
    }
  }

  void selectToAccountById(String? id) {
    if (id == null) return;
    for (final a in ref.read(activeAccountsProvider)) {
      if (a.id == id && a.id != state.account?.id) {
        state = state.copyWith(toAccount: a, phase: QuickEntryPhase.inputting);
        return;
      }
    }
  }

  /// 依名稱選目標帳戶（BDD 綁定用；同帳戶/不存在拋錯——UI 阻擋同帳戶轉帳）。
  void selectToAccount(String name) {
    for (final a in ref.read(activeAccountsProvider)) {
      if (a.name == name && a.id != state.account?.id) {
        state = state.copyWith(toAccount: a, phase: QuickEntryPhase.inputting);
        return;
      }
    }
    throw StateError('目標帳戶不存在（或與來源相同）：$name');
  }

  // ── 儲存/繼續/復原（SDD §5.1 狀態機） ─────────────────────

  /// 儲存（FR-Q5／F02 S2.3 轉帳）：成功 → SavedDialog（顯示本次已記 N 筆）；
  /// 失敗回 Inputting 保留輸入＋錯誤提示（SDD §5.1）。
  void save() {
    if (state.account == null) return;
    if (state.amount.isEmpty) return;
    // 即時求值（PM 2026-10-24：移除 ＝ 鍵 → 運算式直接求值；未完成／÷0 → 停留輸入態）。
    final amountMinor = AmountKeypadEvaluator.evaluate(state.amount);
    if (amountMinor == null || amountMinor <= 0) return;
    if (state.mode == QuickEntryMode.transfer && state.toAccount == null) return;
    state = state.copyWith(phase: QuickEntryPhase.committing);
    final sw = Stopwatch()..start();
    if (state.mode == QuickEntryMode.transfer) {
      // F02 S2.3：轉帳守恆（AC-10）——不計入收支統計；BE 驗證相異帳戶。
      ref.read(saveTransactionProvider).execute(
            accountId: state.account!.id,
            amountMinor: amountMinor,
            occurredAt: state.occurredAt,
            kind: TxKind.transfer,
            toAccountId: state.toAccount!.id,
            note: state.note.isEmpty ? null : state.note,
          );
    } else {
      ref.read(saveTransactionProvider).execute(
            accountId: state.account!.id,
            categoryId: state.category?.id,
            amountMinor: amountMinor,
            occurredAt: state.occurredAt,
            merchant: state.merchant.isEmpty ? null : state.merchant,
            note: state.note.isEmpty ? null : state.note,
            // 收入模式（PM 2026-10-24）＝kind income；支出＝expense。
            kind: state.mode == QuickEntryMode.income
                ? TxKind.income
                : TxKind.expense,
          );
    }
    // 「記住上次」（PM 2026-10-24）：以分類為單位記住金額/帳戶/商家。
    final catId = state.category?.id;
    if (catId != null) {
      ref.read(quickEntryMemoryProvider).remember(
            categoryId: catId,
            amount: '$amountMinor', // 存求值後金額（非運算式）
            accountId: state.account?.id,
            merchant: state.merchant,
          );
    }
    // NFR-01 UI 計時（S1.6）：純入庫耗時（BE P95 已驗 <300ms）。
    state = state.copyWith(
      phase: QuickEntryPhase.savedDialog,
      sessionCount: state.sessionCount + 1,
      lastSaveMs: sw.elapsedMilliseconds,
    );
    // 明細/總覽即時刷新（AC-02）＋全畫面刷新（PM 2026-11-19：資料版本戳）。
    ref.invalidate(ledgerProvider);
    ref.refreshAllData();
  }

  /// 繼續（FR-Q2/Q5）：Sticky 保留帳戶/分類/商家；時間重設為現在（FR-Q5）。
  /// 金額清空由 FE 欄位於相位轉移時處理（SavedDialog→Inputting）。
  void continueEntry() {
    state = state.copyWith(
      phase: QuickEntryPhase.inputting,
      amount: '',
      note: '',
      occurredAt: Clock.now(),
    );
  }

  /// 復原上一筆（FR-Q3）：軟刪除墓標＋oplog；計數減一。
  /// 信用卡預扣交易同步回沖「本期應付」——衍生值即時重算（SDD 原則 2）。
  void undoLast() {
    final result = ref.read(undoLastTransactionProvider).execute();
    if (result == null) return; // 無可復原（如全部已撤）
    state = state.copyWith(sessionCount: state.sessionCount - 1);
    ref.invalidate(ledgerProvider);
    // 復原＝軟刪除墓標 → 「最近刪除」須即時反映（PM 2026-10-25）。
    ref.invalidate(recentDeletionsProvider);
    ref.refreshAllData();
  }
}

final quickEntryControllerProvider =
    NotifierProvider.autoDispose<QuickEntryController, QuickEntryState>(
        QuickEntryController.new);
