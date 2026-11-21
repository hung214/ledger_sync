import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/intl.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/presentation/app_shell.dart';
import 'package:ledger_sync/presentation/screens/ledger/ledger_page.dart';
import 'package:ledger_sync/presentation/screens/ledger/recent_deletions_page.dart';
import 'package:ledger_sync/presentation/screens/quick_entry/quick_entry_controller.dart';
import 'package:ledger_sync/presentation/screens/quick_entry/quick_entry_page.dart';

import '../../test/helpers/in_memory_cloud_adapter.dart';
import '../../test/helpers/db_fixture.dart';
import '../../test/helpers/gherkin/gherkin.dart';

/// F02-FE 情境執行器（@FE @M1 @FR-T @FR-A @P0，5 情境；拆分移至明細編輯）。
///
/// 來源：specs/plan/tests/frontend/F02_transactions-accounts.feature（sync_features.ps1
/// 同步副本，pubspec 資產入包——桌面 App 行程 CWD 非專案根，須 rootBundle 讀）。
/// 句型登記簿：specs/plan/tests/dsl.md §3。綁定：T-H7 自製 runner（TR-9）＋
/// integration_test；背景每情境重建 App（in-memory DB 直寫）。
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final doc = GherkinParser.parse(await rootBundle
      .loadString('integration_test/features/F02_transactions-accounts.feature'));

  testWidgets('F02-FE：交易與帳戶 UI（5 情境：禁用態/轉帳樣式/儲值文案/最近刪除/計算機）',
      (tester) async {
    final w = _World(tester);
    final runner = GherkinRunner();
    _bind(runner, w);
    try {
      final executed = await runner.run(doc, tagFilter: (tags) {
        // 拆分已移至「明細→編輯交易」（PM 2026-10-24）——不在此檔。
        return tags.contains('@FE');
      });
      expect(executed, 5, reason: 'F02-FE 應執行 5 個情境（拆分移至明細編輯，PM 2026-10-24）');
      // ignore: avoid_print
      print(runner.log.join('\n'));
    } finally {
      Clock.unfreeze();
      for (final db in w.dbs) {
        db.close();
      }
      for (final c in w.containers) {
        c.dispose();
      }
    }
  });
}

/// 情境共享狀態（每 Scenario 由 Background 重置；dsl.md §1.5 Given 直寫 DB）。
class _World {
  _World(this.tester);

  final WidgetTester tester;
  final List<AppDatabase> dbs = [];
  final List<ProviderContainer> containers = [];
  AppDatabase? db;
  ProviderContainer? container;
  bool pumped = false;

  /// 名稱 → id（Background 建立時登記）。
  final accounts = <String, String>{};
  final categories = <String, String>{};

  /// 本次 session 所記交易（kind → 金額清單；「明細即時顯示」斷言用）。
  final sessionExpenses = <int>[];
  final sessionTransfers = <int>[];
}

/// 內建集名稱 → 帳戶類型（dsl.md §3.1；F02 儲值語意需 ewallet 類型）。
String _accountType(String name) {
  switch (name) {
    case '票證卡':
      return 'ewallet';
    case '銀行':
      return 'bank';
    default:
      return 'cash';
  }
}

void _bind(GherkinRunner runner, _World w) {
  // ── Background ───────────────────────────────────────────
  runner.on(r'App 已完成首次設定$', (p) async {
    final db = DbFixture.create();
    w.dbs.add(db);
    w.db = db;
    w.pumped = false;
    w.accounts.clear();
    w.categories.clear();
    w.sessionExpenses.clear();
    w.sessionTransfers.clear();
    // M1 無引導頁：啟動即主殼；帳戶/分類由後續 Given 直寫。
  });

  runner.on(r'已建立帳戶「{name}」\(餘額 {amount}\)$', (p) async {
    final id = 'a-${w.accounts.length}';
    await DbFixture.seedAccount(
      w.db!,
      id: id,
      type: _accountType(p['name']!),
      name: p['name']!,
      opening: _amount(p['amount']!),
    );
    w.accounts[p['name']!] = id;
  });

  runner.on(r'已建立分類{names}$', (p) async {
    final names =
        RegExp('「([^」]+)」').allMatches(p['names']!).map((m) => m.group(1)!).toList();
    for (var i = 0; i < names.length; i++) {
      final name = names[i];
      final id = 'c-${w.categories.length}';
      // kind 對齊內建集（first_run_bootstrap）：一般收入 = income，其餘 = expense。
      await DbFixture.seedCategory(
        w.db!,
        id: id,
        kind: name == '一般收入' ? 'income' : 'expense',
        name: name,
      );
      w.categories[name] = id;
    }
  });

  // ── Given：App 與快記（沿 F01 模式；每情境唯一 Key 強制重建樹）──
  runner.on(r'使用者位於{page}頁$', (p) async {
    await _ensureApp(w);
    // F02 情境僅斷言總覽/明細（分頁斷言綁定於各 Then 內處理）。
  });

  // ── When：金額驗證（F02-FE S1）───────────────────────────
  runner.on(r'開啟支出記錄$', (p) async => _ensureQuickEntry(w));

  runner.on(r'輸入金額 {amount}$', (p) async {
    await _ensureQuickEntry(w);
    await w.tester.enterText(find.byKey(const Key('quick-entry-amount')), p['amount']!);
    await w.tester.pump();
  });

  // ── Then：儲存按鈕狀態（F02-FE S1；dsl §3.3）──────────────
  runner.on(r'儲存按鈕為禁用狀態$', (p) async {
    final btn =
        w.tester.widget<FilledButton>(find.byKey(const Key('quick-entry-save')));
    expect(btn.onPressed, isNull, reason: '儲存應為禁用（dsl §3.3：enabled=false）');
  });

  runner.on(r'顯示「{text}」且為可點擊$', (p) async {
    // UI-P4：儲存鈕文案＝`OK 儲存`（PM 2026-10-23）——以包含比對。
    expect(find.textContaining(p['text']!), findsWidgets,
        reason: '應顯示含「${p['text']}」之鈕');
    final btn =
        w.tester.widget<FilledButton>(find.byKey(const Key('quick-entry-save')));
    expect(btn.onPressed, isNotNull, reason: '「${p['text']}」應為可點擊（enabled）');
  });

  // ── When：轉帳（F02-FE S2/S3）───────────────────────────
  runner.on(r'建立轉帳「{from}」→「{to}」金額 {amt}$', (p) async =>
      _saveTransfer(w, from: p['from']!, to: p['to']!, amount: p['amt']!));

  runner.on(r'建立「儲值」交易 {to} 金額 {amt} 來源={from}$', (p) async =>
      _saveTransfer(w, from: p['from']!, to: p['to']!, amount: p['amt']!));

  // ── Then：明細與餘額（F02-FE S2/S3）──────────────────────
  runner.on(r'明細頁即時顯示該 {n} 筆$', (p) async {
    final n = int.parse(p['n']!);
    var visible = 0;
    for (final amt in w.sessionExpenses) {
      if (w.tester.any(find.text('-$amt', skipOffstage: false))) visible++;
    }
    for (final amt in w.sessionTransfers) {
      if (w.tester.any(find.text('$amt', skipOffstage: false))) visible++;
    }
    expect(visible, n, reason: '本次 session 應有 $n 筆即時顯示於明細');
  });

  runner.on(r'顯示「{label}」樣式（非支出圖示）$', (p) async {
    expect(
      w.tester.any(find.text(p['label']!, skipOffstage: false)),
      isTrue,
      reason: '應顯示「${p['label']}」樣式',
    );
    // 轉帳列以**類型圖示圓**表達（🏦；電子票證目標→📲 儲值）——非支出圖示
    // （PM 2026-10-24：交易列改為分類/類型圖示圓，取代原 swap_horiz icon）。
    final rows = find.byType(TxTile, skipOffstage: false);
    expect(
      find.descendant(
          of: rows,
          matching: find.byWidgetPredicate(
              (wd) => wd is Text && (wd.data == '🏦' || wd.data == '📲'),
              skipOffstage: false)),
      findsWidgets,
      reason: '轉帳類型圖示（🏦／📲；非支出圖示）',
    );
  });

  runner.on(r'顯示「{label}」樣式（同一群組）$', (p) async {
    final tiles =
        w.tester.widgetList<TxTile>(find.byType(TxTile, skipOffstage: false)).toList();
    final splitTiles = tiles.where((t) => t.tx.splitGroupId != null).toList();
    expect(splitTiles, hasLength(2), reason: '拆分應有 2 筆子交易');
    expect(splitTiles[0].tx.splitGroupId, splitTiles[1].tx.splitGroupId,
        reason: '兩筆共享同一 split_group_id（FR-T6）');
    // 拆分列標示「拆分 · {分類}」（PM 2026-10-24：圖示改為分類圖示圓，
    // 原 call_split icon 退場）——語意＝拆分群組可辨識。
    expect(
      find.descendant(
          of: find.byType(TxTile, skipOffstage: false),
          matching: find.textContaining('拆分', skipOffstage: false)),
      findsWidgets,
      reason: '拆分樣式標示（拆分 · 分類）',
    );
  });

  runner.on(r'顯示「{text}」（不顯示「{other}」）$', (p) async {
    // F02 S2.4「儲值語意」——**範圍化至交易列（TxTile）**：主殼 IndexedStack
    // 同時建入所有分頁，全頁文字斷言會被其他頁面誤判（2026-10-22 UI 整合後
    // 明細新增「支出」篩選 chip 即觸發）。斷言語意＝該筆列顯示儲值而非支出。
    final rows = find.byType(TxTile, skipOffstage: false);
    expect(
      find.descendant(
          of: rows, matching: find.text(p['text']!, skipOffstage: false)),
      findsWidgets,
      reason: '交易列應顯示「${p['text']}」（F02 S2.4 儲值語意）',
    );
    expect(
      find.descendant(
          of: rows, matching: find.text(p['other']!, skipOffstage: false)),
      findsNothing,
      reason: '交易列不應顯示「${p['other']}」',
    );
  });

  runner.on(r'帳戶「{name}」餘額顯示為 {amount}$', (p) async {
    await _ensureApp(w);
    // 導航至總覽（NavigationBar；冪等——已作用中再點無副作用）。
    await w.tester.tap(find.byKey(const Key('nav-總覽')));
    await w.tester.pumpAndSettle();
    final fmt = NumberFormat('#,###').format(_amount(p['amount']!));
    expect(find.text('餘額 $fmt'), findsOneWidget, reason: '總覽餘額卡（千分位）');
  });

  // ── Given：刪除目標（F02-FE S4；dsl §3.1 基準日凍結）─────
  runner.on(r'已存在一筆支出 {amount} 元$', (p) async {
    // 基準日凍結：對齊情境日期算術（刪除日 2026/10/19 → 2026/11/18 = +30 曆日）。
    Clock.freeze(DateTime(2026, 10, 19, 12));
    final amount = _amount(p['amount']!);
    const id = 'tx-del-1';
    await DbFixture.seedTx(
      w.db!,
      id: id,
      kind: 'expense',
      amountMinor: amount,
      accountId: w.accounts['現金']!,
      category: w.categories['交通'],
      occurredAt: Clock.now().millisecondsSinceEpoch,
    );
    w.sessionExpenses.add(amount); // 「明細即時顯示（已移除）」斷言用
  });

  // ── When：刪除與時間（F02-FE S4）────────────────────────
  runner.on(r'刪除該筆交易$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-明細')));
    await w.tester.pumpAndSettle();
    // 點該筆（session 最後一筆支出）→ bottom sheet「刪除」。
    final amt = w.sessionExpenses.last;
    await w.tester.tap(find.text('-$amt'));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('tx-delete')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'模擬系統時間為 {dt}$', (p) async => Clock.freeze(_dateTime(p['dt']!)));

  // ── Then：軟刪除即時反映（F02-FE S4）─────────────────────
  runner.on(r'明細頁即時顯示該 {n} 筆（已移除）$', (p) async {
    final n = int.parse(p['n']!);
    var removed = 0;
    for (final amt in w.sessionExpenses) {
      if (!w.tester.any(find.text('-$amt', skipOffstage: false))) removed++;
    }
    expect(removed, n, reason: '該 $n 筆應已自明細移除（軟刪除即時反映）');
  });

  runner.on(r'設定→「最近刪除」顯示 {n} 筆（剩餘 {days} 天）$', (p) async {
    await _openRecentDeletions(w);
    final n = int.parse(p['n']!);
    final rows = find.textContaining('剩餘', skipOffstage: false);
    expect(w.tester.widgetList<Text>(rows).length, n, reason: '最近刪除應顯示 $n 筆');
    if (n > 0) {
      expect(
        w.tester.any(find.text('剩餘 ${p['days']!} 天')),
        isTrue,
        reason: '剩餘天數應為 ${p['days']}（曆日計）',
      );
    }
  });

  runner.on(r'設定→「最近刪除」顯示 {n} 筆$', (p) async {
    await _openRecentDeletions(w);
    final n = int.parse(p['n']!);
    final rows = find.textContaining('剩餘', skipOffstage: false);
    expect(w.tester.widgetList<Text>(rows).length, n,
        reason: '最近刪除應顯示 $n 筆（0＝空狀態；30 曆日窗口）');
  });

  // ── Then／When：計算機鍵盤（F02-FE S2.9）─────────────────
  runner.on(r'金額欄下方顯示常駐計算機鍵盤$', (p) async {
    expect(
      w.tester.any(find.byKey(const Key('amount-keypad'))),
      isTrue,
      reason: '金額欄下方應有常駐計算機鍵盤（S2.9：不彈系統鍵盤）',
    );
  });

  runner.on(r'以計算機鍵盤計算 {expr}$', (p) async {
    for (final ch in p['expr']!.split('')) {
      await w.tester.tap(find.byKey(Key('keypad-${_keypadLabel(ch)}')));
      await w.tester.pump();
    }
    await w.tester.tap(find.byKey(const Key('keypad-＝')));
    await w.tester.pump();
  });

  runner.on(r'於計算機鍵盤按 {key}$', (p) async {
    await w.tester.tap(find.byKey(Key('keypad-${p['key']}')));
    await w.tester.pump();
  });

  runner.on(r'金額欄顯示 {value}$', (p) async {
    final state = _amountEditableState(w);
    expect(state.widget.controller.text, p['value'],
        reason: '金額欄應顯示 ${p['value']}（＝ 求值；TWD 四捨五入整數元）');
  });
}

// ── 綁定輔助（沿 F01 模式）─────────────────────────────────

Future<void> _ensureApp(_World w) async {
  if (w.pumped) return;
  final container = ProviderContainer(overrides: [
    dbProvider.overrideWithValue(w.db!),
    // 啟動同步鉤子（FR-Y11 afterSave——F07-BE 接線）防 UnimplementedError。
    syncCoordinatorProvider.overrideWithValue(
        SyncCoordinator(w.db!, InMemoryCloudAdapter(), deviceId: 'd-A')),
  ]);
  w.containers.add(container);
  w.container = container;
  // 每情境以唯一 Key 強制重建整棵樹——否則 const AppShell 會複用 element，
  // Navigator 路由堆疊（前情境的快記頁/對話框）殘留並掛著舊 container/DB。
  await w.tester.pumpWidget(
    KeyedSubtree(
      key: ValueKey('app-shell-${w.dbs.length}'),
      child: UncontrolledProviderScope(container: container, child: const AppShell()),
    ),
  );
  await w.tester.pumpAndSettle();
  w.pumped = true;
}

Future<void> _ensureQuickEntry(_World w) async {
  await _ensureApp(w);
  if (w.tester.any(find.byType(QuickEntryPage))) return;
  await w.tester.tap(find.byKey(const Key('fab-quick-entry')));
  await w.tester.pumpAndSettle();
  expect(w.tester.any(find.byType(QuickEntryPage)), isTrue, reason: '快記頁應已開啟');
}

/// 建立轉帳（S2/S3 共用）：切轉帳模式 → 選來源/目標 → 輸入 → 儲存 → 完成。
Future<void> _saveTransfer(
  _World w, {
  required String from,
  required String to,
  required String amount,
}) async {
  await _ensureQuickEntry(w);
  final ctrl = w.container!.read(quickEntryControllerProvider.notifier);
  ctrl.setMode(QuickEntryMode.transfer);
  ctrl.selectAccount(from);
  ctrl.selectToAccount(to);
  await w.tester.enterText(find.byKey(const Key('quick-entry-amount')), amount);
  await w.tester.pump();
  ctrl.save();
  w.sessionTransfers.add(int.parse(amount));
  await w.tester.pumpAndSettle(); // SavedDialog
  await w.tester.tap(find.text('完成'));
  await w.tester.pumpAndSettle(); // 返回主殼
}

/// 開啟「最近刪除」（F02-FE S4）：入口＝明細 AppBar（M1 無設定頁，F07）。
/// 已在頁內則先返回——凍結時間後需重新進入以重算窗口（Clock 不觸發 rebuild）。
Future<void> _openRecentDeletions(_World w) async {
  await _ensureApp(w);
  if (w.tester.any(find.byType(RecentDeletionsPage))) {
    await w.tester.pageBack();
    await w.tester.pumpAndSettle();
  }
  await w.tester.tap(find.byKey(const Key('nav-明細')));
  await w.tester.pumpAndSettle();
  await w.tester.tap(find.byKey(const Key('ledger-recent-deletions')));
  await w.tester.pumpAndSettle();
  expect(w.tester.any(find.byType(RecentDeletionsPage)), isTrue,
      reason: '最近刪除頁應已開啟');
}

int _amount(String s) => int.parse(s.trim().replaceAll(',', ''));

/// ASCII 運算子 → 鍵面全寬標籤（dsl §3.2：`+ - * /` 映射 ＋－×÷）。
String _keypadLabel(String ch) {
  switch (ch) {
    case '+':
      return '＋';
    case '-':
      return '－';
    case '*':
      return '×';
    case '/':
      return '÷';
    default:
      return ch; // 0-9 與全寬運算子原樣
  }
}

EditableTextState _amountEditableState(_World w) {
  final finder = find.descendant(
      of: find.byKey(const Key('quick-entry-amount')),
      matching: find.byType(EditableText));
  return w.tester.state<EditableTextState>(finder);
}

DateTime _dateTime(String s) {
  final m = RegExp(r'^(\d{4})/(\d{2})/(\d{2})(?: (\d{1,2}):(\d{2}))?$').firstMatch(s.trim());
  if (m == null) throw FormatException('日期時間格式未支援：$s（dsl.md §1-3）');
  return DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    m.group(4) == null ? 0 : int.parse(m.group(4)!),
    m.group(5) == null ? 0 : int.parse(m.group(5)!),
  );
}
