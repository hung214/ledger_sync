import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/appearance/theme_mode_state.dart';
import '../../../application/categories/category_service.dart';
import '../../../application/providers.dart';
import '../../category_display.dart';
import 'amount_keypad.dart';
import 'category_picker_dialog.dart';
import 'quick_date_time_picker.dart';
import 'quick_entry_controller.dart';

/// 快記頁（FR-Q1~Q8，acceptance F01）。
///
/// - 欄位：帳戶/分類/商家（Sticky）＋金額/時間（每筆重設）。
/// - 金額欄 autofocus（S1.1-5：數字鍵盤已自動聚焦）。
/// - 時間欄：QuickDateTimePicker bottom sheet，不離開快記頁（FR-Q8，S1.5）。
/// - 儲存 → SavedDialog「繼續記下一筆？」（繼續/復原上一筆/完成，FR-Q2）。
///
/// 帳戶/分類選擇器採 PopupMenuButton（全受控——顯示即 controller 狀態；
/// DropdownButtonFormField.initialValue 為 FormField 初值語意，狀態變更
/// 後不更新顯示，不符合智慧預設/固定預設動態切換）。
class QuickEntryPage extends ConsumerStatefulWidget {
  const QuickEntryPage({super.key});

  @override
  ConsumerState<QuickEntryPage> createState() => _QuickEntryPageState();
}

class _QuickEntryPageState extends ConsumerState<QuickEntryPage> {
  final _amountCtrl = TextEditingController();

  /// 備註欄（PM 2026-10-24：手機與 PC 皆有）。
  final _noteCtrl = TextEditingController();

  /// 商家欄（需與 state 同步——「記住上次」會帶入上次商家）。
  final _merchantCtrl = TextEditingController();

  /// 計算機運算式（F02 S2.9；受控——顯示於金額欄，＝ 求值後為純數字）。
  String _expr = '';

  /// 兩層式分類（PM 2026-10-22）：展開之子類別所屬主類別。
  String? _selectedMainId;

  /// 分類即時新增後的刷新（providers 讀 db 快取，需 invalidate 兩分類集）。
  void _refreshCategories() {
    ref.invalidate(expenseCategoriesProvider);
    ref.invalidate(incomeCategoriesProvider);
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    _merchantCtrl.dispose();
    super.dispose();
  }

  /// 相位轉移驅動（SDD §5.1）：入 SavedDialog → 彈每筆確認；離開 → 金額清空。
  void _onPhaseChange(QuickEntryPhase? prev, QuickEntryPhase next) {
    if (prev == null) return;
    if (next == QuickEntryPhase.savedDialog && prev != QuickEntryPhase.savedDialog) {
      showDialog<void>(
        context: context,
        builder: (_) => SavedDialog(onFinish: () => Navigator.of(context).pop()),
      );
    }
    if (prev == QuickEntryPhase.savedDialog && next != QuickEntryPhase.savedDialog) {
      _amountCtrl.clear(); // 繼續：金額清空（FR-Q5 Sticky 不含金額）
      _noteCtrl.clear(); // 備註屬每筆欄位（不 Sticky）
      setState(() => _expr = ''); // 計算機運算式隨金額重設（F02 S2.9）
    }
  }

  /// 計算機輸入（F02 S2.9）：運算式 → 金額欄顯示＋controller 同步
  /// （儲存啟用由 int.tryParse 決定——運算式未完成自然禁用）。
  void _onKeypadExpr(String expr) {
    setState(() => _expr = expr);
    _amountCtrl.text = expr;
    ref.read(quickEntryControllerProvider.notifier).setAmount(expr);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(quickEntryControllerProvider);
    final controller = ref.read(quickEntryControllerProvider.notifier);
    final accounts = ref.watch(activeAccountsProvider);
    // 分類集依模式（支出／收入；PM 2026-10-24）。
    final categories = ref.watch(state.mode == QuickEntryMode.income
        ? incomeCategoriesProvider
        : expenseCategoriesProvider);
    // 分類索引＋顯示規則（PM 2026-10-25：共用 category_display——修正子類別
    // icon='' 導致 `??` 不回退主類別圖示之缺陷）。
    final catById = categoryIndex(categories);
    ref.listen(
      quickEntryControllerProvider.select((s) => s.phase),
      (prev, next) => _onPhaseChange(prev, next),
    );
    // 欄位 ↔ state 同步（PM 2026-10-24）：「記住上次」帶入金額/商家、繼續清空
    // 金額/備註時，受控文字欄須反映（金額欄亦驅動計算機運算式顯示）。
    ref.listen(
      quickEntryControllerProvider
          .select((s) => (s.amount, s.merchant, s.note)),
      (prev, next) {
        if (!mounted) return;
        final (amount, merchant, note) = next;
        if (_amountCtrl.text != amount) _amountCtrl.text = amount;
        if (_merchantCtrl.text != merchant) _merchantCtrl.text = merchant;
        if (_noteCtrl.text != note) _noteCtrl.text = note;
        if (_expr != amount) setState(() => _expr = amount);
      },
    );

    final themeMode = ref.watch(themeModeProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('快速記帳'),
        actions: [
          // 主題切換（PM 2026-10-22：亮/暗按鈕——亮色以 01/02 白卡風格為準）。
          IconButton(
            key: const Key('qe-theme-toggle'),
            tooltip: themeMode == ThemeMode.dark ? '切換淺色' : '切換深色',
            onPressed: () => ref.read(themeModeProvider.notifier).set(
                themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark),
            icon: Icon(themeMode == ThemeMode.dark
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                children: [
                  // 模式列（PM 2026-10-24 定稿）：**僅 支出／收入／轉帳**。
                  // 「拆分」移至明細→編輯交易；「預算」設定走預算頁表單。
                  SegmentedButton<QuickEntryMode>(
                    key: const Key('quick-entry-mode'),
                    segments: const [
                      ButtonSegment(
                          value: QuickEntryMode.expense, label: Text('支出')),
                      ButtonSegment(
                          value: QuickEntryMode.income, label: Text('收入')),
                      ButtonSegment(
                          value: QuickEntryMode.transfer, label: Text('轉帳')),
                    ],
                    selected: {state.mode},
                    onSelectionChanged: (modes) =>
                        controller.setMode(modes.first),
                  ),
                  const SizedBox(height: 12),
                  // 金額大顯示（**03 雛型：置中**——PM 2026-10-25：手機版以 03 為準）。
                  TextField(
                    key: const Key('quick-entry-amount'),
                    controller: _amountCtrl,
                    autofocus: true, // S1.1-5
                    keyboardType: TextInputType.none, // 常駐鍵盤（F02 S2.9）
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .displaySmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                    decoration: const InputDecoration(
                        hintText: '0', border: InputBorder.none),
                    onChanged: controller.setAmount,
                  ),
                  // 金額下方小字＝**帳戶（Sticky）**（03 雛型；PM 2026-10-25）。
                  Center(
                    child: Text(
                        state.account == null
                            ? '帳戶：未選擇'
                            : '帳戶：${state.account!.name}（Sticky）',
                        style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.outline)),
                  ),
                  const SizedBox(height: 4),
                  // PM 2026-10-25：分類**不再平鋪**（03／10 雛型）——改由下方「分類」欄
                  // 開彈窗；三欄快捷格僅保留於**桌面面板**（08 雛型）。
                  // 日期（PM 2026-10-23）：◀▶ 快調 ±1 天；點擊開日曆（不離開頁）。
                  // FittedBox：窄幅自動縮放（永不溢出；2026-10-24 修 55px 溢出）。
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                      IconButton(
                        key: const Key('date-prev'),
                        iconSize: 30,
                        tooltip: '前一天',
                        onPressed: () => controller.setOccurredAt(
                            state.occurredAt.subtract(const Duration(days: 1))),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      TextButton(
                        key: const Key('quick-entry-time'),
                        style: TextButton.styleFrom(
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => QuickDateTimePicker(
                              initial: state.occurredAt,
                              onSelected: controller.setOccurredAt,
                            ),
                          );
                        },
                        child: Text(
                          _dateLabel(state.occurredAt),
                          // PM 2026-10-23：日期放大（1.5×）。
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                  fontSize: 20, fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        key: const Key('date-next'),
                        iconSize: 30,
                        tooltip: '後一天',
                        onPressed: () => controller.setOccurredAt(
                            state.occurredAt.add(const Duration(days: 1))),
                        icon: const Icon(Icons.chevron_right),
                      ),
                      ],
                    ),
                  ),
                  // 帳戶 ｜ 分類（原型 10：**同一列兩欄**）；轉帳＝來源｜目標帳戶。
                  // IntrinsicHeight＋stretch＝兩欄方框**等高**（欄位天然高不同也不歪）。
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _pickerField(
                            key: const Key('quick-entry-account'),
                            label: state.mode == QuickEntryMode.transfer
                                ? '來源帳戶'
                                : '帳戶',
                            text: state.account?.name ?? '選擇帳戶',
                            entries: accounts
                                .map((a) => (a.id, a.name, false))
                                .toList(),
                            recent: const [],
                            onSelected: controller.selectAccountById,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: state.mode == QuickEntryMode.transfer
                              ? _pickerField(
                                  key: const Key('quick-entry-target'),
                                  label: '目標帳戶',
                                  text: state.toAccount?.name ?? '選擇目標帳戶',
                                  // 同帳戶轉帳 UI 阻擋（S2.3 邊界）：目標排除來源。
                                  entries: accounts
                                      .where((a) => a.id != state.account?.id)
                                      .map((a) => (a.id, a.name, false))
                                      .toList(),
                                  recent: const [],
                                  onSelected: controller.selectToAccountById,
                                )
                              // 分類欄（PM 2026-10-24）：點選 → 彈窗（上常用／左主／右子）；
                              // 顯示「主類別 emoji ＋ 類別名」（子類別＝主類別 emoji＋子名）。
                              : InkWell(
                                  key: const Key('quick-entry-category'),
                                  onTap: _openCategoryPicker,
                                  child: InputDecorator(
                                    decoration: const InputDecoration(
                                        labelText: '分類',
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                        // 03 雛型「›」：可點提示（與輸入欄位區隔）。
                                        suffixIcon: Icon(Icons.chevron_right,
                                            size: 18)),
                                    child: Text(
                                        state.category == null
                                            ? '選擇分類'
                                            : categoryLabelOf(state.category!,
                                                byId: catById),
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (state.mode == QuickEntryMode.transfer)
                    // 轉帳：分類／商家不適用（原型 10 手機 B）。
                    TextField(
                      enabled: false,
                      decoration: const InputDecoration(
                          labelText: '分類／商家',
                          hintText: '不適用（轉帳語意）',
                          border: OutlineInputBorder(),
                          isDense: true),
                    )
                  else
                    TextField(
                      key: const Key('quick-entry-merchant'),
                      controller: _merchantCtrl,
                      decoration: const InputDecoration(
                          labelText: '商家',
                          border: OutlineInputBorder(),
                          isDense: true),
                      onChanged: controller.setMerchant,
                    ),
                  const SizedBox(height: 12),
                  // 備註（PM 2026-10-24；選填；轉帳亦適用）。
                  TextField(
                    key: const Key('quick-entry-note'),
                    controller: _noteCtrl,
                    decoration: const InputDecoration(
                        labelText: '備註（選填）',
                        border: OutlineInputBorder(),
                        isDense: true),
                    onChanged: controller.setNote,
                  ),
                  // 本次已記 N 筆（03 雛型；PM 2026-10-25。附件 📷 先不做）。
                  if (state.sessionCount > 0) ...[
                    const SizedBox(height: 10),
                    Center(
                      child: Text('本次已記 ${state.sessionCount} 筆',
                          style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.outline)),
                    ),
                  ],
                ],
              ),
            ),
            // 浮動底部面板（PM 2026-10-22）：OK 儲存鈕在計算機**上方**，
            // 計算機貼底常駐（不隨內容捲動）。
            Container(
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context)
                        .colorScheme
                        .shadow
                        .withValues(alpha: 0.18),
                    blurRadius: 14,
                    offset: const Offset(0, -3),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // OK 已移入鍵盤第一排（PM 2026-10-24：C／⌫／OK；移除「＝」）。
                  AmountKeypad(
                    expr: _expr,
                    onExprChanged: _onKeypadExpr,
                    onOk: controller.save,
                    okEnabled: quickEntrySaveEnabled(state),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 分類選擇彈窗（PM 2026-10-24）：上方常用／左主類別／右子類別；
  /// 回傳結果 → 選定（帶入上次金額/帳戶/商家）或「＋即建即選」。
  Future<void> _openCategoryPicker() async {
    final st = ref.read(quickEntryControllerProvider);
    final pick = await showCategoryPicker(
      context,
      ref,
      kind: st.mode == QuickEntryMode.income ? 'income' : 'expense',
      selectedId: st.category?.id,
    );
    if (!mounted || pick == null) return;
    switch (pick) {
      case CategoryPicked(:final categoryId):
        ref.read(quickEntryControllerProvider.notifier)
            .selectCategoryById(categoryId);
      case CategoryAddRequested(:final asSub, :final parentId):
        await _quickAddCategory(asSub: asSub, parentId: parentId);
    }
  }

  /// 分類即時新增（PM 2026-10-24：彈窗各欄「＋」）：名稱即建，
  /// 重名走 CategoryService 拒絕提示；建立後立即選取。
  Future<void> _quickAddCategory(
      {required bool asSub, String? parentId}) async {
    parentId ??= asSub ? _selectedMainId : null;
    if (asSub && parentId == null) return; // 無選中主類別不可加子分類
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(asSub ? '新增子分類' : '新增主類別'),
        content: TextField(
          key: const Key('quick-add-category-name'),
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '分類名稱'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('取消')),
          FilledButton(
              key: const Key('quick-add-category-save'),
              onPressed: () =>
                  Navigator.of(dialogCtx).pop(ctrl.text.trim()),
              child: const Text('建立')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      final row = CategoryService(ref.read(dbProvider)).create(
          kind: ref.read(quickEntryControllerProvider).mode ==
                  QuickEntryMode.income
              ? 'income'
              : 'expense',
          name: name,
          parentId: parentId);
      _refreshCategories();
      ref.read(quickEntryControllerProvider.notifier).selectCategoryById(row.id);
      if (!asSub) setState(() => _selectedMainId = row.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// 日期顯示（中文星期；不依賴 intl locale 初始化——測試直接 pump 也安全）。
  static const _weekdays = ['週一', '週二', '週三', '週四', '週五', '週六', '週日'];

  // PM 2026-10-24：手機日期標籤去年份（03 雛型）——亦解決窄幅 Row 溢出。
  static String _dateLabel(DateTime t) =>
      '${DateFormat('MM/dd').format(t)}'
      '（${_weekdays[t.weekday - 1]}）'
      '${DateFormat('HH:mm').format(t)}';


  /// 分類選單項（主類別→子分類縮排；FR-B1 階層）。
  /// 第三元素＝是否子分類（結構化縮排渲染——文字保持原樣供精確比對）。
  Widget _pickerField({
    required Key key,
    required String label,
    required String text,
    required List<(String, String, bool)> entries,
    required List<(String, String, String?)> recent,
    required void Function(String?) onSelected,
    VoidCallback? addCategoryAction, // 分類選擇器專用：＋新增分類（PM 2026-10-22）
  }) {
    return PopupMenuButton<String>(
      key: key,
      initialValue: null,
      onSelected: onSelected,
      itemBuilder: (_) => [
        // ＋新增分類（PM 2026-10-22）：**選單頂部**常駐（長清單底部
        // 項目在 LazyListView 未建/超出畫面，底部入口會點不到）。
        if (addCategoryAction != null)
          PopupMenuItem<String>(
            key: const Key('picker-add-category'),
            onTap: addCategoryAction,
            child: Row(children: [
              Icon(Icons.add,
                  size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              const Text('新增分類'),
            ]),
          ),
        // 常用類別（FR-B1 常用區）：最近使用 10 個，常駐最上方。
        if (recent.isNotEmpty) ...[
          const PopupMenuItem(
            enabled: false,
            height: 34,
            child: Text('常用',
                style:
                    TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ),
          for (final (id, name, _) in recent)
            PopupMenuItem(
              key: Key('recent-cat-$name'),
              value: id,
              child: Row(children: [
                Icon(Icons.history,
                    size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Text(name),
              ]),
            ),
          const PopupMenuDivider(),
        ],
        for (final (id, name, isSub) in entries)
          PopupMenuItem(
            value: id,
            child: isSub
                ? Padding(
                    padding: const EdgeInsets.only(left: 28),
                    child: Row(children: [
                      const Icon(Icons.subdirectory_arrow_right, size: 14),
                      const SizedBox(width: 4),
                      Text(name),
                    ]),
                  )
                : Text(name),
          ),
      ],
      child: InputDecorator(
        // 方框＋緊湊（PM 2026-10-25：與分類欄一致——原型 10 皆為方框）。
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        child: Text(text, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// OK 儲存啟用判定（**手機與桌面共用**；PM 2026-10-25）。
///
/// 即時求值（PM 2026-10-24：移除 ＝ 鍵）——運算式未完成／無效 → 金額未定 → 禁用；
/// 轉帳另需目標帳戶。
bool quickEntrySaveEnabled(QuickEntryState state) {
  final amountOk = (AmountKeypadEvaluator.evaluate(state.amount) ?? 0) > 0;
  switch (state.mode) {
    case QuickEntryMode.transfer:
      return amountOk && state.toAccount != null;
    case QuickEntryMode.expense:
    case QuickEntryMode.income:
      return amountOk;
  }
}

class SavedDialog extends ConsumerWidget {
  const SavedDialog({super.key, required this.onFinish});

  /// 「完成」：關閉對話框後返回進入前畫面（FR-Q2，S1.9）。
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(quickEntryControllerProvider);
    final controller = ref.read(quickEntryControllerProvider.notifier);
    return AlertDialog(
      title: const Text('繼續記下一筆？'),
      content: Text('本次已記 ${state.sessionCount} 筆'),
      actions: [
        TextButton(
          onPressed: () {
            controller.continueEntry();
            Navigator.of(context).pop();
          },
          child: const Text('繼續'),
        ),
        TextButton(
          onPressed: controller.undoLast,
          child: const Text('復原上一筆'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
            onFinish();
          },
          child: const Text('完成'),
        ),
      ],
    );
  }
}
