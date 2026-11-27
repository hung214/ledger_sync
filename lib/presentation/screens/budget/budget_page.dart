import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/budgets/budget_evaluator.dart';
import '../../../application/budgets/budget_period_service.dart';
import '../../../application/budgets/budget_service.dart';
import '../../../application/categories/category_service.dart';
import '../../../application/providers.dart';
import '../../../application/stats/monthly_stats_service.dart';
import '../../../core/clock.dart';
import '../../../data/sqlite/app_database.dart';
import '../../theme/app_theme.dart';
import '../quick_entry/amount_keypad.dart';
import '../quick_entry/category_picker_dialog.dart';

/// 預算頁（FR-B2~B7 呈現面；UI-P3 對照 04-budget 雛型）。
///
/// - **總預算卡**：週期標題＋百分比（色）＋大金額＋進度條＋
///   「剩餘 · 每日可用 · 月底預測（含預扣）」摘要行（FR-B2/B3）。
/// - **分類預算卡**：各分類 bitem——用量/額度（千分位）＋百分比＋
///   預扣標籤（FR-B5）＋**日均**（已用/經過天數）＋進度條
///   （<80% 主色、≥80% 橙、≥100% 紅——AC-05）＋超支紅字（記帳不封鎖）。
/// - **收入目標卡**（FR-B6）：達標率（>100% 不封頂）＋badge。
/// - **本月結餘卡**（FR-B7）：預計（目標−總預算）／實際（含預扣）兩行並列。
/// - 用量為衍生值（SDD 原則 2）：訂閱 ledgerProvider 即時刷新（AC-02）。
class BudgetPage extends ConsumerStatefulWidget {
  const BudgetPage({super.key});

  @override
  ConsumerState<BudgetPage> createState() => _BudgetPageState();
}

class _BudgetPageState extends ConsumerState<BudgetPage> {
  int _version = 0; // 表單儲存後刷新（預算非交易——ledgerProvider 不覆蓋）

  Future<void> _openForm({_BudgetFormInitial? initial}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BudgetFormSheet(initial: initial),
    );
    if (saved == true) setState(() => _version++);
  }

  @override
  Widget build(BuildContext context) {
    // 訂閱交易變化（儲存/刪除/還原後即時刷新）；_version 蓋表單儲存路徑。
    ref.watch(ledgerProvider);
    final db = ref.watch(dbProvider);
    final budgets = db.allBudgets();
    final total = budgets.where((b) => b.categoryId == null).toList();
    final categoryBudgets = budgets.where((b) => b.categoryId != null).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('預算'),
        actions: [
          IconButton(
            key: const Key('budget-add'),
            tooltip: '新增預算',
            onPressed: () => _openForm(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: budgets.isEmpty && db.activeIncomeGoal() == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.savings_outlined,
                    size: 40,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 8),
                  const Text('尚無預算——右上角「＋」開始設定'),
                ],
              ),
            )
          : ListView(
              key: ValueKey('budget-list-$_version'),
              padding: const EdgeInsets.all(12),
              children: [
                if (total.isNotEmpty)
                  _TotalBudgetCard(
                    budget: total.first,
                    onEdit: () => _openForm(
                      initial: _BudgetFormInitial.total(total.first),
                    ),
                  ),
                if (categoryBudgets.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _CategoryBudgetsCard(
                    budgets: categoryBudgets,
                    onEdit: (b) =>
                        _openForm(initial: _BudgetFormInitial.category(b)),
                  ),
                ],
                const SizedBox(height: 4),
                _IncomeGoalCard(
                  onEdit: () {
                    final g = ref.read(dbProvider).activeIncomeGoal();
                    if (g != null) {
                      _openForm(initial: _BudgetFormInitial.goal(g));
                    }
                  },
                ),
                const SizedBox(height: 4),
                const _BalanceCard(),
              ],
            ),
    );
  }
}

/// 表單初始狀態（模式由內容推導：總預算/分類預算/收入目標）。
class _BudgetFormInitial {
  const _BudgetFormInitial.total(this.row) : goal = null;
  const _BudgetFormInitial.category(this.row) : goal = null;
  const _BudgetFormInitial.goal(this.goal) : row = null;

  final BudgetRow? row;
  final IncomeGoalRow? goal;

  String get mode =>
      row != null ? (row!.categoryId == null ? 'total' : 'category') : 'goal';
}

/// 預算表單（2026-10-22 補全：App 內建立/編輯——本機可用性缺口）。
///
/// 三型：總預算／分類預算／收入目標（Segmented）；金額＋週期起始日（1~28，
/// FR-B2/B3）；編輯模式可刪（軟刪除）。keys：budget-type-*／budget-amount／
/// budget-start-day／budget-category／budget-save／budget-delete。
class _BudgetFormSheet extends ConsumerStatefulWidget {
  const _BudgetFormSheet({this.initial});

  final _BudgetFormInitial? initial;

  @override
  ConsumerState<_BudgetFormSheet> createState() => _BudgetFormSheetState();
}

class _BudgetFormSheetState extends ConsumerState<_BudgetFormSheet> {
  late String _mode;
  late final TextEditingController _amount;
  late final TextEditingController _startDay;
  String? _categoryId;

  /// 計算機作用欄位（PM 2026-11-26：金額**與**週期起始日皆由小算盤輸入，
  /// 不跳系統鍵盤——聚焦哪個欄位，計算機就編輯哪個）。
  /// 可見性（同編輯交易）：兩欄皆失焦 → 小算盤向下滑出。
  final _amountFocus = FocusNode();
  final _startDayFocus = FocusNode();
  String _keypadTarget = 'amount';
  bool _keypadVisible = false;

  void _onTargetFocus() {
    final startDay = _startDayFocus.hasFocus;
    final t = startDay ? 'startDay' : 'amount';
    final visible = _amountFocus.hasFocus || startDay;
    if ((t != _keypadTarget || visible != _keypadVisible) && mounted) {
      setState(() {
        _keypadTarget = t;
        _keypadVisible = visible;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _amountFocus.addListener(_onTargetFocus);
    _startDayFocus.addListener(_onTargetFocus);
    final init = widget.initial;
    _mode = init?.mode ?? 'total';
    _amount = TextEditingController(
      text: '${init?.row?.amountMinor ?? init?.goal?.amountMinor ?? ''}',
    );
    _startDay = TextEditingController(
      text: '${init?.row?.periodStartDay ?? init?.goal?.periodStartDay ?? 1}',
    );
    _categoryId = init?.row?.categoryId;
  }

  @override
  void dispose() {
    _amountFocus.dispose();
    _startDayFocus.dispose();
    _amount.dispose();
    _startDay.dispose();
    super.dispose();
  }

  void _save() {
    final service = BudgetService(ref.read(dbProvider));
    // 計算機輸入（聚焦滑入制 PM 2026-11-26）：金額欄＝運算式 → 即時求值
    // （AmountKeypadEvaluator；TWD 四捨五入整數元）。
    final amount = AmountKeypadEvaluator.evaluate(_amount.text) ?? 0;
    var day = int.tryParse(_startDay.text) ?? 1;
    day = day.clamp(1, 28);
    switch (_mode) {
      case 'total':
        service.setTotalBudget(amountMinor: amount, periodStartDay: day);
      case 'category':
        final cat = _categoryId;
        if (cat == null) return;
        service.setCategoryBudget(
          categoryId: cat,
          amountMinor: amount,
          periodStartDay: day,
        );
      case 'goal':
        service.setIncomeGoal(amountMinor: amount, periodStartDay: day);
    }
    Navigator.of(context).pop(true);
  }

  void _delete() {
    final row = widget.initial?.row;
    if (row != null) {
      BudgetService(ref.read(dbProvider)).remove(row.id);
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final expenseCats = ref
        .watch(expenseCategoriesProvider)
        .where((c) => c.deletedAt == null)
        .toList();
    // 預設分類＝首個主類別（平面清單首位會是子分類——sort_order NULL 排序語意）。
    final mainCats = expenseCats.where((c) => c.parentId == null).toList();
    final defaultCatId = mainCats.isNotEmpty
        ? mainCats.first.id
        : expenseCats.first.id;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<String>(
                    key: const Key('budget-type'),
                    segments: const [
                      ButtonSegment(
                        value: 'total',
                        label: Text('總預算'),
                        icon: Icon(Icons.savings),
                      ),
                      ButtonSegment(
                        value: 'category',
                        label: Text('分類預算'),
                        icon: Icon(Icons.label_outline),
                      ),
                      ButtonSegment(
                        value: 'goal',
                        label: Text('收入目標'),
                        icon: Icon(Icons.flag),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) => setState(() {
                      _mode = s.first;
                      // 切入分類模式即綁定預設分類（否則 _categoryId=null 靜默不存）。
                      if (_mode == 'category') {
                        _categoryId ??= defaultCatId;
                      }
                    }),
                  ),
                  if (_mode == 'category') ...[
                    const SizedBox(height: 12),
                    // 分類選擇（PM 2026-11-23：與快記同款——**MRU 前 5** 優先＋
                    // 主類別點選才展開子類別；＋即建即選）。
                    InkWell(
                      key: const Key('budget-category'),
                      onTap: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final pick = await showCategoryPicker(
                          context,
                          ref,
                          kind: 'expense',
                          selectedId: _categoryId ?? defaultCatId,
                          recentLimit: 5,
                          // T71 PM 2026-11-24：預算可綁主分類——用量＝主分類
                          // ＋其全部子分類加總（早餐100＋午餐200 → 餐飲食品 300）。
                          pickMainLabel: '整個主分類（含子類別）',
                        );
                        if (!mounted) return;
                        switch (pick) {
                          case CategoryPicked(:final categoryId):
                            // picker 的 context 已過 async gap——用 State.context。
                            if (!context.mounted) return;
                            setState(() => _categoryId = categoryId);
                          case CategoryAddRequested(
                            :final asSub,
                            :final parentId,
                          ):
                            // ＋即建即選（快記同款）。
                            if (!mounted || !context.mounted) return;
                            final nameCtrl = TextEditingController();
                            final name = await showDialog<String>(
                              context: context,
                              builder: (dialogCtx) => AlertDialog(
                                title: Text(asSub ? '新增子分類' : '新增主類別'),
                                content: TextField(
                                  autofocus: true,
                                  controller: nameCtrl,
                                  decoration: const InputDecoration(
                                    labelText: '分類名稱',
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(dialogCtx).pop(),
                                    child: const Text('取消'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.of(dialogCtx)
                                            .pop(nameCtrl.text.trim()),
                                    child: const Text('建立'),
                                  ),
                                ],
                              ),
                            );
                            if (name == null || name.isEmpty || !mounted) {
                              return;
                            }
                            try {
                              final row = CategoryService(ref.read(dbProvider))
                                  .create(
                                    kind: 'expense',
                                    name: name,
                                    parentId: parentId,
                                  );
                              if (!mounted) return;
                              setState(() => _categoryId = row.id);
                            } catch (e) {
                              if (mounted) {
                                messenger.showSnackBar(
                                  SnackBar(content: Text('$e')),
                                );
                              }
                            }
                          default:
                            break;
                        }
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: '分類（點選；MRU 5＋兩層）',
                          border: OutlineInputBorder(),
                        ),
                        child: Text(
                          expenseCats
                                  .where(
                                    (c) =>
                                        c.id == (_categoryId ?? defaultCatId),
                                  )
                                  .map((c) => c.name)
                                  .firstOrNull ??
                              '未選擇',
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  // 金額＝唯讀顯示運算式（計算機聚焦滑入——PM 2026-11-26）。
                  // PM 2026-11-27 桌面（≥900）：金額欄可用**實體鍵盤**輸入
                  // 運算式（過濾僅數字/運算子）；手機維持唯讀＋計算機輸入。
                  Builder(
                    builder: (context) {
                      final isPhone = MediaQuery.sizeOf(context).width < 900;
                      return TextField(
                        key: const Key('budget-amount'),
                        controller: _amount,
                        focusNode: _amountFocus,
                        readOnly: isPhone,
                        showCursor: true,
                        keyboardType: isPhone
                            ? TextInputType.none
                            : TextInputType.text,
                        inputFormatters: isPhone
                            ? null
                            : [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9+\-*/(). ]'),
                                ),
                              ],
                        // ASCII 運算子→全寬（評估器語法；controller 已持有
                        // 文字——僅必要時改寫＋觸發重建同步鍵盤顯示/儲存判定）。
                        onChanged: (v) => setState(() {
                          final n =
                              AmountKeypadEvaluator.normalizeHardwareOperators(
                                v,
                              );
                          if (n != v) _amount.text = n;
                        }),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                        decoration: const InputDecoration(
                          labelText: '金額（元）',
                          border: OutlineInputBorder(),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  // 週期起始日＝唯讀顯示（計算機輸入——聚焦切換計算機作用
                  // 欄位；PM 2026-11-26：不跳系統鍵盤）。
                  TextField(
                    key: const Key('budget-start-day'),
                    controller: _startDay,
                    focusNode: _startDayFocus,
                    readOnly: true,
                    showCursor: true,
                    keyboardType: TextInputType.none,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: const InputDecoration(
                      labelText: '週期起始日（1~28；FR-B2）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (widget.initial?.row != null)
                        TextButton(
                          key: const Key('budget-delete'),
                          onPressed: _delete,
                          child: const Text(
                            '刪除',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const Key('budget-save'),
                        onPressed: _save,
                        child: const Text('儲存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // ── 底部固定列（PM 2026-11-26：同編輯交易——聚焦金額／起始日 →
          // 計算機由下滑入；皆失焦 → 向下滑出）。
          const SizedBox(height: 8),
          FocusSlideKeypad(
            visible: _keypadVisible,
            // 壓住小算盤向下滑 → 只收小算盤（失焦），不關表單。
            onDragDismiss: () => FocusScope.of(context).unfocus(),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context).colorScheme.shadow
                        .withValues(alpha: 0.18),
                    blurRadius: 14,
                    offset: const Offset(0, -3),
                  ),
                ],
              ),
              child: AmountKeypad(
                // 計算機編輯「聚焦中的欄位」（金額或週期起始日）。
                expr: _keypadTarget == 'startDay'
                    ? _startDay.text
                    : _amount.text,
                onExprChanged: (expr) => setState(() {
                  if (_keypadTarget == 'startDay') {
                    _startDay.text = expr;
                  } else {
                    _amount.text = expr;
                  }
                }),
                onOk: _save,
                okEnabled:
                    (AmountKeypadEvaluator.evaluate(_amount.text) ?? 0) > 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 預算進度條（共用：BudgetPage／總覽橫幅）。
///
/// <80% 主色、≥80% 橙、≥100% 紅（AC-05）；key = budget-progress-{名稱}。
class BudgetProgressBar extends StatelessWidget {
  const BudgetProgressBar({
    super.key,
    required this.name,
    required this.usageMinor,
    required this.amountMinor,
  });

  final String name;
  final int usageMinor;
  final int amountMinor;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final over = usageMinor > amountMinor;
    final progressColor = over
        ? tokens.danger
        : (usageMinor * 5 >= amountMinor * 4 ? tokens.warning : null);
    return LinearProgressIndicator(
      key: Key('budget-progress-$name'),
      value: amountMinor <= 0 ? 0 : min(usageMinor / amountMinor, 1.0),
      color: progressColor,
      backgroundColor: tokens.track,
    );
  }
}

/// 週期摘要（天數計算——每日可用/月底預測共用）。
class _PeriodInfo {
  _PeriodInfo._(this.start, this.endInclusive, this.today);

  factory _PeriodInfo.of(int startDay) {
    final now = Clock.now();
    final period = const BudgetPeriodService().periodOf(startDay, now);
    return _PeriodInfo._(
      DateTime.fromMillisecondsSinceEpoch(period.startMs),
      DateTime.fromMillisecondsSinceEpoch(period.endExclusiveMs)
          .subtract(const Duration(days: 1)),
      DateTime(now.year, now.month, now.day),
    );
  }

  final DateTime start;
  final DateTime endInclusive;
  final DateTime today;

  int get elapsedDays => today.difference(start).inDays + 1; // 含今天
  int get remainingDays => endInclusive.difference(today).inDays + 1; // 含今天
  int get totalDays => endInclusive.difference(start).inDays + 1;

  /// 標題短版（雛型：10/1~10/31）。
  String get displayShort =>
      '${start.month}/${start.day}~${endInclusive.month}/${endInclusive.day}';
}

/// 進度色（<80% 主色、≥80% 橙、≥100% 紅——AC-05）。
Color _pctColor(BuildContext context, double pct) {
  final tokens = AppTokens.of(context);
  if (pct >= 100) return tokens.danger;
  if (pct >= 80) return tokens.warning;
  return Theme.of(context).colorScheme.primary;
}

/// 總預算卡（FR-B2/B3）：摘要行「剩餘 · 每日可用 · 月底預測（含預扣）」。
class _TotalBudgetCard extends ConsumerWidget {
  const _TotalBudgetCard({required this.budget, this.onEdit});

  final BudgetRow budget;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final evaluator = BudgetEvaluator(db);
    final usage = evaluator.totalUsageMinor() ?? 0;
    final amount = budget.amountMinor;
    final info = _PeriodInfo.of(budget.periodStartDay);
    final pct = amount <= 0 ? 0.0 : usage * 100 / amount;
    final remaining = max(amount - usage, 0);
    // 每日可用（FR-B3）＝剩餘 ÷ 剩餘天數（含今天）。
    final dailyAvailable = info.remainingDays <= 0
        ? 0
        : remaining ~/ info.remainingDays;
    // 月底預測（含預扣）＝已用 ÷ 經過天數 × 全月天數。
    final forecast = info.elapsedDays <= 0
        ? 0
        : (usage / info.elapsedDays * info.totalDays).round();
    final fmt = NumberFormat('#,###');

    return Card(
      key: const Key('budget-total-card'),
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '總預算（週期 ${info.displayShort}）',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                  Text(
                    '${pct.toStringAsFixed(0)}%',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: _pctColor(context, pct),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    fmt.format(usage),
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      '/ ${fmt.format(amount)}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              BudgetProgressBar(
                name: '總預算',
                usageMinor: usage,
                amountMinor: amount,
              ),
              const SizedBox(height: 8),
              Text(
                '剩餘 ${fmt.format(remaining)} · '
                '每日可用 ${fmt.format(dailyAvailable)} · '
                '月底預測 ${fmt.format(forecast)}（含預扣）',
                key: const Key('budget-total-summary'),
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: Theme.of(context).colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分類預算卡（單卡多項——雛型 bitem 版式）。
class _CategoryBudgetsCard extends ConsumerWidget {
  const _CategoryBudgetsCard({required this.budgets, this.onEdit});

  final List<BudgetRow> budgets;
  final void Function(BudgetRow)? onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final evaluator = BudgetEvaluator(db);
    final fmt = NumberFormat('#,###');
    // 主分類 id 集合（T71——主分類預算列標示「（含子類）」）。
    final parentIds = {
      for (final c in db.categoriesByKind('expense'))
        if (c.parentId == null) c.id,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '分類預算',
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: 4),
            for (final b in budgets)
              _CategoryItem(
                name:
                    (db.categoryName(b.categoryId!) ?? '分類預算') +
                    (parentIds.contains(b.categoryId) ? '（含子類）' : ''),
                usage: evaluator.categoryUsage(b.categoryId!),
                amountMinor: b.amountMinor,
                periodStartDay: b.periodStartDay,
                fmt: fmt,
                onEdit: onEdit == null ? null : () => onEdit!(b),
              ),
          ],
        ),
      ),
    );
  }
}

/// 分類預算項（雛型 bitem）：百分比色／用量/額度／預扣標籤／日均／進度條。
class _CategoryItem extends ConsumerWidget {
  const _CategoryItem({
    required this.name,
    required this.usage,
    required this.amountMinor,
    required this.periodStartDay,
    required this.fmt,
    this.onEdit,
  });

  final String name;
  final CategoryUsage? usage;
  final int amountMinor;
  final int periodStartDay;
  final NumberFormat fmt;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = usage;
    final total = u?.totalMinor ?? 0;
    final pending = u?.pendingMinor ?? 0;
    final pct = amountMinor <= 0 ? 0.0 : total * 100 / amountMinor;
    final info = _PeriodInfo.of(periodStartDay);
    // 日均（雛型語意）＝已用 ÷ 經過天數。
    final dailyAvg = info.elapsedDays <= 0 ? 0 : total ~/ info.elapsedDays;
    final over = total > amountMinor;
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${pct.toStringAsFixed(pct == pct.roundToDouble() ? 0 : 1)}%',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: _pctColor(context, pct),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Text(
                  '${fmt.format(total)} / ${fmt.format(amountMinor)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (pending > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondaryContainer
                          .withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '預扣 ${fmt.format(pending)}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  over
                      ? '超支 ${fmt.format(total - amountMinor)}'
                      : '日均 ${fmt.format(dailyAvg)}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: over
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            BudgetProgressBar(
              name: name,
              usageMinor: total,
              amountMinor: amountMinor,
            ),
          ],
        ),
      ),
    );
  }
}

/// 收入目標卡（FR-B6）：達標率 badge（>100% 不封頂）＋已入帳/目標。
class _IncomeGoalCard extends ConsumerWidget {
  const _IncomeGoalCard({this.onEdit});

  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final status = BudgetEvaluator(db).incomeGoalStatus();
    if (status == null) {
      return const SizedBox.shrink();
    }
    final pct = status.ratePercent;
    return Card(
      key: const Key('budget-income-card'),
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '收入目標',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: status.achieved
                          ? Theme.of(context).colorScheme.primaryContainer
                                .withValues(alpha: 0.7)
                          : Theme.of(context).colorScheme.secondaryContainer
                                .withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      status.achieved ? '已達成 $pct%' : '進行中 $pct%',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: status.achieved
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context)
                                  .colorScheme
                                  .onSecondaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    NumberFormat('#,###').format(status.achievedMinor),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: status.achieved
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      '/ 目標 ${NumberFormat('#,###').format(status.goalMinor)}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              BudgetProgressBar(
                name: '收入目標',
                usageMinor: status.achievedMinor,
                amountMinor: status.goalMinor,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 本月結餘卡（FR-B7）：預計（目標−總預算）／實際（含預扣）兩行並列。
class _BalanceCard extends ConsumerWidget {
  const _BalanceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    final evaluator = BudgetEvaluator(db);
    final income = MonthlyStatsService(db).incomeMinorThisMonth();
    final expense = MonthlyStatsService(db).expenseMinorThisMonth();
    final totalBudget = db
        .allBudgets()
        .where((b) => b.categoryId == null)
        .map((b) => b.amountMinor)
        .fold(0, (a, b) => a + b);
    final goal = evaluator.incomeGoalStatus()?.goalMinor;
    final projected = goal == null ? null : goal - totalBudget;
    final actual = income - expense;
    final fmt = NumberFormat('#,###');

    Widget row(String label, String value, Color? color) => Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: Theme.of(context).colorScheme.outline),
          ),
        ),
        Text(
          value,
          key: Key('balance-$label'),
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(color: color, fontWeight: FontWeight.w700),
        ),
      ],
    );

    return Card(
      key: const Key('budget-balance-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本月結餘',
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: 8),
            if (projected != null)
              row(
                '預計（目標−總預算）',
                fmt.format(projected),
                projected >= 0 ? Theme.of(context).colorScheme.primary : null,
              ),
            const SizedBox(height: 6),
            row(
              '實際（含預扣）',
              fmt.format(actual),
              actual >= 0 ? Theme.of(context).colorScheme.primary : null,
            ),
          ],
        ),
      ),
    );
  }
}
