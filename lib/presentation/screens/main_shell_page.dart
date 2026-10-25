import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../category_display.dart';
import 'settings/settings_hub_page.dart';
import '../../core/version.dart';
import 'budget/budget_page.dart';
import 'ledger/ledger_page.dart';
import 'overview/overview_page.dart';
import 'package:intl/intl.dart';

import 'quick_entry/quick_entry_controller.dart';
import 'quick_entry/category_picker_dialog.dart';
import 'quick_entry/amount_keypad.dart';
import '../../application/categories/category_service.dart';
import 'quick_entry/quick_date_time_picker.dart';
import 'quick_entry/quick_entry_page.dart';
import 'scan/scan_page.dart';
import '../../application/sync/sync_fe_state.dart';
import 'stats/stats_page.dart';

/// 主殼（SDD §8 IA；RWD 響應式——單碼庫雙殼，ui/08-desktop-shell 雛型落地）：
/// - 窄（< 900px，手機/窄窗）→ 底部 NavigationBar。
/// - 寬（≥ 900px，桌面）→ 左側 NavigationRail（對齊 08 桌面殼雛型側欄）。
/// - 分頁：總覽/明細/預算/統計；桌面快捷鍵 ⌘N/Ctrl+N 開快記（FR-Q7，F01-S1.11）。
/// - 快記為全頁面推入，「完成」返回進入前分頁（FR-Q2）。
class MainShellPage extends ConsumerStatefulWidget {
  const MainShellPage({super.key});

  static const _tabs = [
    (OverviewPage(), '總覽', Icons.home_outlined, Icons.home),
    (LedgerPage(), '明細', Icons.receipt_long_outlined, Icons.receipt_long),
    (BudgetPage(), '預算', Icons.savings_outlined, Icons.savings),
    (StatsPage(), '統計', Icons.query_stats_outlined, Icons.query_stats),
  ];

  @override
  ConsumerState<MainShellPage> createState() => _MainShellPageState();
}

class _MainShellPageState extends ConsumerState<MainShellPage> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // FR-Y11 啟動同步：已連結雲端時同步一次（fire-and-forget；M5 BE 已驗協議）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // FR-T5 啟動檢查（N-7）——FE 情境由 harness 統一驅動（雙鉤子會漏計）；
      // 生產接線待 F06-FE 收尾（AutoSync 風格）。
      if ((ref.read(dbProvider).getSetting('sync.account') ?? '').isNotEmpty) {
        ref.read(syncCoordinatorProvider).sync().then((_) {
          final db = ref.read(dbProvider);
          db.setSetting('sync.last_at', '${DateTime.now().millisecondsSinceEpoch}');
          ref.read(pendingOpsProvider.notifier).refresh();
          ref.read(lastSyncAtProvider.notifier).refresh();
          ref.read(syncEventsProvider.notifier).refresh();
        }).catchError((_) {});
      }
    });
  }

  void _openQuickEntry() => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const QuickEntryPage()),
      );

  // 設定入口已移至總覽 AppBar（SettingsHubPage——M7 恢復，PM 2026-10-21）。

  /// 掃描入口（FR-S6：桌面快捷鍵 ⌘⇧S/Ctrl+Shift+S；無相機→匯入）。
  void _openScan() => openScanFlow(context, ref);

  @override
  Widget build(BuildContext context) {
    final tabs = MainShellPage._tabs;
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        // FR-Q7 桌面快捷鍵（F01-S1.11）：⌘N（macOS）／Ctrl+N（其餘）。
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): const _OpenQuickEntryIntent(),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): const _OpenQuickEntryIntent(),
        // FR-S6 掃描快捷鍵（F03-FE S6）：⌘⇧S／Ctrl+Shift+S。
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true):
            const _OpenScanIntent(),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true):
            const _OpenScanIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _OpenQuickEntryIntent: CallbackAction<_OpenQuickEntryIntent>(
            onInvoke: (_) => _openQuickEntry(),
          ),
          _OpenScanIntent: CallbackAction<_OpenScanIntent>(
            onInvoke: (_) => _openScan(),
          ),
        },
        child: Focus(
          autofocus: true,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final body = IndexedStack(
                index: _tab,
                children: [for (final (page, _, _, _) in tabs) page],
              );
              if (!wide) {
                // 手機殼：底部 NavigationBar。
                return Scaffold(
                  body: body,
                  floatingActionButton: FloatingActionButton(
                    key: const Key('fab-quick-entry'),
                    tooltip: '快記',
                    onPressed: _openQuickEntry,
                    child: const Icon(Icons.add),
                  ),
                  bottomNavigationBar: NavigationBar(
                    selectedIndex: _tab,
                    onDestinationSelected: (i) => setState(() => _tab = i),
                    destinations: [
                      for (final (_, label, icon, selected) in tabs)
                        NavigationDestination(
                          key: Key('nav-$label'),
                          icon: Icon(icon),
                          selectedIcon: Icon(selected),
                          label: label,
                        ),
                    ],
                  ),
                );
              }
              // 桌面殼（08-desktop-shell 三欄；PM 2026-10-23 與手機版明確區分）：
              // 深色側邊導航（190px）＋工具列（搜尋/掃描/快記）＋主內容＋右側快記常駐面板（320px）。
              return Scaffold(
                body: Row(
                  children: [
                    _DesktopSideNav(
                      tabs: [for (final (_, label, icon, _) in tabs) (label, icon)],
                      current: _tab,
                      onSelect: (i) => setState(() => _tab = i),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          _DesktopToolbar(
                            onScan: _openScan,
                            onQuick: _openQuickEntry,
                            onSearch: (_) => setState(() => _tab = 1),
                          ),
                          Expanded(child: body),
                        ],
                      ),
                    ),
                    const _DesktopQuickPanel(),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 快記開啟意圖（快捷鍵動作目標）。
class _OpenQuickEntryIntent extends Intent {
  const _OpenQuickEntryIntent();
}

/// 掃描開啟意圖（快捷鍵動作目標；FR-S6）。
class _OpenScanIntent extends Intent {
  const _OpenScanIntent();
}

/// 桌面側邊導航（08 雛型：深色 190px＋logo＋導航＋版本/雲端狀態）。
class _DesktopSideNav extends ConsumerWidget {
  const _DesktopSideNav({
    required this.tabs,
    required this.current,
    required this.onSelect,
  });

  final List<(String, IconData)> tabs;
  final int current;
  final void Function(int) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final synced = (ref.watch(dbProvider).getSetting('sync.account') ?? '')
        .isNotEmpty;
    return Container(
      width: 190,
      color: const Color(0xFF0B2B29), // 08 雛型側欄深色（亮/暗主題皆同——桌面辨識）
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('📒 LedgerSync',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 18),
          for (final (i, (label, icon)) in tabs.indexed)
            InkWell(
              // key 沿用 nav-{label}（f02/f08 harness 相依；雙殼互斥不衝突）。
              key: Key('nav-$label'),
              borderRadius: BorderRadius.circular(10),
              onTap: () => onSelect(i),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                margin: const EdgeInsets.only(bottom: 2),
                decoration: BoxDecoration(
                  color: current == i
                      ? const Color(0xFF0B7A75)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(icon,
                        size: 18,
                        color: current == i
                            ? Colors.white
                            : const Color(0xFFCFE3E1)),
                    const SizedBox(width: 10),
                    Text(label,
                        style: TextStyle(
                            fontSize: 13,
                            color: current == i
                                ? Colors.white
                                : const Color(0xFFCFE3E1),
                            fontWeight: current == i
                                ? FontWeight.w700
                                : null)),
                  ],
                ),
              ),
            ),
          // 設定（08 導航含 ⚙️設定——Hub 頁）。
          InkWell(
            key: const Key('desktop-nav-設定'),
            borderRadius: BorderRadius.circular(10),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const SettingsHubPage())),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: const Row(children: [
                Icon(Icons.settings_outlined,
                    size: 18, color: Color(0xFFCFE3E1)),
                SizedBox(width: 10),
                Text('設定',
                    style: TextStyle(
                        fontSize: 13, color: Color(0xFFCFE3E1))),
              ]),
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('v$appVersion · 本地優先\n${synced ? '已連結：Google Drive' : '雲端未設定'}',
                style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFFCFE3E1),
                    height: 1.6)),
          ),
        ],
      ),
    );
  }
}

/// 桌面工具列（08：搜尋＋掃描＋快速記帳）。
class _DesktopToolbar extends StatelessWidget {
  const _DesktopToolbar({
    required this.onScan,
    required this.onQuick,
    required this.onSearch,
  });

  final VoidCallback onScan;
  final VoidCallback onQuick;
  final void Function(String) onSearch;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: TextField(
                key: const Key('desktop-search'),
                decoration: InputDecoration(
                  hintText: '🔍 搜尋交易（關鍵字／金額／分類／期間）— Ctrl+F',
                  isDense: true,
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none),
                ),
                onSubmitted: onSearch,
              ),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            key: const Key('desktop-scan'),
            onPressed: onScan,
            icon: const Icon(Icons.photo_camera_outlined, size: 16),
            label: const Text('掃描'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            key: const Key('fab-quick-entry'), // harness 相依 key（桌面＝工具列快記鈕）
            onPressed: onQuick,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('快速記帳'),
          ),
        ],
      ),
    );
  }
}

/// 桌面右側快記常駐面板（08：金額＋分類格＋meta＋儲存；320px）。
class _DesktopQuickPanel extends ConsumerStatefulWidget {
  const _DesktopQuickPanel();

  @override
  ConsumerState<_DesktopQuickPanel> createState() => _DesktopQuickPanelState();
}

class _DesktopQuickPanelState extends ConsumerState<_DesktopQuickPanel> {
  final _amountCtrl = TextEditingController();

  /// 計算機運算式（PM 2026-10-25：桌面面板亦常駐鍵盤——與手機共用元件）。
  String _expr = '';

  /// 備註欄（PM 2026-10-24：PC 面板亦有）。
  final _noteCtrl = TextEditingController();

  /// 商家欄（與 state 同步——「記住上次」會帶入）。
  final _merchantCtrl = TextEditingController();

  static const _wd = ['一', '二', '三', '四', '五', '六', '日'];

  static String _fmt(DateTime t) =>
      '${DateFormat('MM/dd').format(t)}（${_wd[t.weekday - 1]}） '
      '${DateFormat('HH:mm').format(t)}';

  /// 分類選擇彈窗（PM 2026-10-24；與手機共用同一元件）。
  Future<void> _openCategoryPicker() async {
    final st = ref.read(quickEntryControllerProvider);
    final kind = st.mode == QuickEntryMode.income ? 'income' : 'expense';
    final pick = await showCategoryPicker(context, ref,
        kind: kind, selectedId: st.category?.id);
    if (!mounted || pick == null) return;
    switch (pick) {
      case CategoryPicked(:final categoryId):
        ref
            .read(quickEntryControllerProvider.notifier)
            .selectCategoryById(categoryId);
      case CategoryAddRequested(:final asSub, :final parentId):
        await _quickAddCategory(kind: kind, asSub: asSub, parentId: parentId);
    }
  }

  /// 分類即建即選（PM 2026-10-24：彈窗各欄「＋」→ 名稱對話框 → 建立後選取）。
  Future<void> _quickAddCategory(
      {required String kind, required bool asSub, String? parentId}) async {
    if (asSub && parentId == null) return;
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
              onPressed: () => Navigator.of(dialogCtx).pop(ctrl.text.trim()),
              child: const Text('建立')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      final row = CategoryService(ref.read(dbProvider))
          .create(kind: kind, name: name, parentId: parentId);
      ref.invalidate(expenseCategoriesProvider);
      ref.invalidate(incomeCategoriesProvider);
      ref.read(quickEntryControllerProvider.notifier).selectCategoryById(row.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// 面板儲存（原大按鈕行為；PM 2026-10-25 改由鍵盤 OK 觸發）。
  void _saveFromPanel() {
    final controller = ref.read(quickEntryControllerProvider.notifier);
    controller.save();
    final s = ref.read(quickEntryControllerProvider);
    if (s.phase == QuickEntryPhase.savedDialog) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '已入庫（${s.lastSaveMs} ms）· 本次已記 ${s.sessionCount} 筆')));
      _amountCtrl.clear();
      _noteCtrl.clear();
      controller.setAmount(''); // FR-Q5：金額清空（Sticky 其餘保留）
      controller.setNote('');
      if (mounted) setState(() => _expr = '');
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    _merchantCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(quickEntryControllerProvider);
    final controller = ref.read(quickEntryControllerProvider.notifier);
    final accounts = ref.watch(activeAccountsProvider);
    // 分類集依模式（支出／收入各自獨立；轉帳無分類——PM 2026-10-24）。
    final categories = ref.watch(state.mode == QuickEntryMode.income
        ? incomeCategoriesProvider
        : expenseCategoriesProvider);
    // 分類欄顯示（PM 2026-10-24/25：與手機一致——共用 category_display；
    // 子類別＝**主類別 emoji ＋ 子類別名**；非圖示庫代碼→🏷️，與類別設定一致）。
    final catById = categoryIndex(categories);
    final selCat = state.category;
    final selCatLabel = selCat == null
        ? '選擇分類'
        : categoryLabelOf(selCat, byId: catById);
    // 欄位 ↔ state 同步（PM 2026-10-24）：記住上次帶入金額/商家時反映。
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

    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(left: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('快速記帳',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          Text('Ctrl+N 聚焦 · 常駐面板', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 8),
          // 模式列（PM 2026-10-24：僅 支出／收入／轉帳；三種模式類別各自獨立）。
          SegmentedButton<QuickEntryMode>(
            key: const Key('desktop-quick-mode'),
            segments: const [
              ButtonSegment(
                  value: QuickEntryMode.expense, label: Text('支出')),
              ButtonSegment(value: QuickEntryMode.income, label: Text('收入')),
              ButtonSegment(
                  value: QuickEntryMode.transfer, label: Text('轉帳')),
            ],
            selected: {state.mode},
            onSelectionChanged: (m) => controller.setMode(m.first),
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('desktop-quick-amount'),
            controller: _amountCtrl,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(fontWeight: FontWeight.w800),
            decoration: InputDecoration(
              hintText: '0',
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
            onChanged: controller.setAmount,
          ),
          const SizedBox(height: 10),
          // PM 2026-10-25：**移除個別主類別選項**（三欄快捷格）——分類一律由
          // 「分類」欄開啟彈窗（⭐ 常用類別／左主／右子）。
          // 日期列（PM 2026-10-24）：◀▶ 快調 ±1 天；點日期開日曆。
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                key: const Key('desktop-quick-date-prev'),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 30, minHeight: 30),
                tooltip: '前一天',
                onPressed: () => controller.setOccurredAt(
                    state.occurredAt.subtract(const Duration(days: 1))),
                icon: const Icon(Icons.chevron_left, size: 20),
              ),
              TextButton(
                key: const Key('desktop-quick-date'),
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => QuickDateTimePicker(
                    initial: state.occurredAt,
                    onSelected: controller.setOccurredAt,
                  ),
                ),
                child: Text(_fmt(state.occurredAt),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                key: const Key('desktop-quick-date-next'),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 30, minHeight: 30),
                tooltip: '後一天',
                onPressed: () => controller.setOccurredAt(
                    state.occurredAt.add(const Duration(days: 1))),
                icon: const Icon(Icons.chevron_right, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            key: const Key('desktop-quick-account'),
            initialValue: state.account?.id,
            isDense: true,
            decoration: const InputDecoration(
                labelText: '帳戶', isDense: true, border: OutlineInputBorder()),
            items: [
              for (final a in accounts)
                DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (v) => v == null ? null : controller.selectAccountById(v),
          ),
          const SizedBox(height: 8),
          if (state.mode == QuickEntryMode.transfer) ...[
            // 轉帳：目標帳戶（同帳戶阻擋；分類/商家不適用）。
            DropdownButtonFormField<String>(
              key: const Key('desktop-quick-target'),
              initialValue: state.toAccount?.id,
              isDense: true,
              decoration: const InputDecoration(
                  labelText: '目標帳戶',
                  isDense: true,
                  border: OutlineInputBorder()),
              items: [
                for (final a in accounts)
                  if (a.id != state.account?.id)
                    DropdownMenuItem(value: a.id, child: Text(a.name)),
              ],
              onChanged: (v) =>
                  v == null ? null : controller.selectToAccountById(v),
            ),
          ] else ...[
            // 分類欄（PM 2026-10-24）：與手機一致——點選開彈窗（上常用／左主／右子），
            // 選取後顯示所選分類（含子類別名稱）。
            InkWell(
              key: const Key('desktop-quick-category'),
              onTap: _openCategoryPicker,
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: '分類',
                    isDense: true,
                    border: OutlineInputBorder()),
                child: Text(selCatLabel),
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (state.mode != QuickEntryMode.transfer)
            TextField(
              key: const Key('desktop-quick-merchant'),
              controller: _merchantCtrl,
              decoration: const InputDecoration(
                  labelText: '商家',
                  isDense: true,
                  border: OutlineInputBorder()),
              onChanged: controller.setMerchant,
            ),
          const SizedBox(height: 8),
          // 備註（PM 2026-10-24）。
          TextField(
            key: const Key('desktop-quick-note'),
            controller: _noteCtrl,
            decoration: const InputDecoration(
                labelText: '備註（選填）',
                isDense: true,
                border: OutlineInputBorder()),
            onChanged: controller.setNote,
          ),
          const Spacer(),
          // 常駐計算機鍵盤（PM 2026-10-25：桌面面板**與手機共用同一元件**，
          // OK 跨兩格；原獨立大按鈕「OK 儲存（Enter）」已移除）。
          AmountKeypad(
            expr: _expr,
            onExprChanged: (e) => setState(() => _expr = e),
            onOk: _saveFromPanel,
            okEnabled: quickEntrySaveEnabled(state),
          ),
          Text('儲存後停留此面板繼續記（每筆確認）',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}
