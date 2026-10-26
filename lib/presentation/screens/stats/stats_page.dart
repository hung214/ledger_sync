import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/providers.dart';
import '../../../application/reports/report_service.dart';
import '../../theme/app_theme.dart';
import 'category_donut.dart';

/// 統計頁（FR-R2 呈現面；**v3 整頁重做——PM 2026-10-26 對齊 11-stats 雛型**）。
///
/// - **月份列**：`◀`／`2026/10`＋小字「期間（月份）」／`▶`——三者皆**白底圓角外框**
///   （原為底線輸入框，風格不符）。
/// - **三卡**：支出（紅）／收入（綠）／淨額（收−支）——**底色＋外框**。
/// - **分類占比（本月）**：白卡＋甜甜圈（`CategoryDonut`：百分比**圈外引線**，不壓扇區）
///   ＋**色點圖例**（`{名稱} {pct}%`＋金額；色點與扇區同索引同色）。
///   **依「主類別」彙總**（子類別歸其所屬主類別；PM 2026-10-26）。
/// - **月趨勢（支出）**：白卡＋長條圖（觸摸顯示金額）＋`{m}月 {總計}` 明細列。
/// - 訂閱 ledgerProvider 即時刷新（AC-02）；既有數值文字契約不變
///   （`合計`／`{名稱} {pct}%`／`{m}月 {總計}`）。
class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key});

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends ConsumerState<StatsPage> {
  (int, int)? _selected; // (year, month)；null = 最新有資料月份

  /// 月份位移（◀▶；跨年）。
  void _shiftMonth(int delta) {
    final cur = _selected ?? _latest();
    if (cur == null) return;
    final d = DateTime(cur.$1, cur.$2 + delta);
    setState(() => _selected = (d.year, d.month));
  }

  (int, int)? _latest() {
    final db = ref.read(dbProvider);
    final months = db
        .allTransactions()
        .where((t) => t.deletedAt == null)
        .map((t) {
          final d = DateTime.fromMillisecondsSinceEpoch(t.occurredAt);
          return (d.year, d.month);
        })
        .toSet()
        .toList()
      ..sort((a, b) =>
          a.$1 == b.$1 ? b.$2.compareTo(a.$2) : b.$1.compareTo(a.$1));
    return months.isEmpty ? null : months.first;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(ledgerProvider); // 交易變化即時刷新
    final db = ref.watch(dbProvider);
    final expenseTxs = db
        .allTransactions()
        .where((t) => t.deletedAt == null && t.kind == 'expense')
        .toList();
    final incomeTxs = db
        .allTransactions()
        .where((t) => t.deletedAt == null && t.kind == 'income')
        .toList();
    final months = expenseTxs
        .map((t) {
          final d = DateTime.fromMillisecondsSinceEpoch(t.occurredAt);
          return (d.year, d.month);
        })
        .toSet()
        .toList()
      ..sort((a, b) => b.$1.compareTo(a.$1) != 0
          ? b.$1.compareTo(a.$1)
          : b.$2.compareTo(b.$2));
    final selected = _selected ?? (months.isEmpty ? null : months.first);
    final fmt = NumberFormat('#,###');
    final tokens = AppTokens.of(context);

    // 月趨勢（僅列出有資料月份，升冪）。
    final trend = <(int, int), int>{};
    for (final t in expenseTxs) {
      final d = DateTime.fromMillisecondsSinceEpoch(t.occurredAt);
      trend[(d.year, d.month)] = (trend[(d.year, d.month)] ?? 0) + t.amountMinor;
    }
    final trendKeys = trend.keys.toList()
      ..sort((a, b) => a.$1.compareTo(b.$1) != 0
          ? a.$1.compareTo(b.$1)
          : a.$2.compareTo(b.$2));

    // 分類占比＝**依主類別彙總**（PM 2026-10-26）。
    final report = selected == null
        ? null
        : ReportService(db).aggregateByMain(selected.$1, selected.$2);

    // 收入合計／淨額（選定月份）。
    int incomeTotal = 0;
    if (selected != null) {
      for (final t in incomeTxs) {
        final d = DateTime.fromMillisecondsSinceEpoch(t.occurredAt);
        if (d.year == selected.$1 && d.month == selected.$2) {
          incomeTotal += t.amountMinor;
        }
      }
    }
    final expenseTotal = report?.totalMinor ?? 0;
    final net = incomeTotal - expenseTotal;
    final shares =
        report?.shares.where((s) => s.amountMinor > 0).toList() ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('統計')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // 月份列（11 雛型）：◀／月份框（含「期間（月份）」小字）／▶——皆外框。
          Row(children: [
            _MonthNavButton(
              key: const Key('stats-month-prev'),
              icon: Icons.chevron_left,
              tooltip: '上個月',
              onTap: () => _shiftMonth(-1),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: PopupMenuButton<(int, int)>(
                key: const Key('stats-month'),
                tooltip: '選擇月份',
                onSelected: (m) => setState(() => _selected = m),
                itemBuilder: (_) => [
                  for (final m in months)
                    PopupMenuItem(value: m, child: Text('${m.$2}月')),
                ],
                child: _BorderedBox(
                  padding:
                      const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  child: Column(children: [
                    Text(
                        selected == null
                            ? '—'
                            : '${selected.$1}/${selected.$2.toString().padLeft(2, '0')}',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                    Text('期間（月份）',
                        style: TextStyle(fontSize: 10, color: tokens.subText)),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _MonthNavButton(
              key: const Key('stats-month-next'),
              icon: Icons.chevron_right,
              tooltip: '下個月',
              onTap: () => _shiftMonth(1),
            ),
          ]),
          const SizedBox(height: 12),
          if (report != null && selected != null) ...[
            // 三卡：支出／收入／淨額——**底色＋外框**（PM 2026-10-26）。
            Row(children: [
              _SummaryCard(
                  label: '支出',
                  value: '-${fmt.format(expenseTotal)}',
                  color: tokens.danger),
              const SizedBox(width: 8),
              _SummaryCard(
                  label: '收入',
                  value: '+${fmt.format(incomeTotal)}',
                  color: tokens.success),
              const SizedBox(width: 8),
              _SummaryCard(
                  label: '淨額',
                  value: '${net < 0 ? '-' : ''}${fmt.format(net.abs())}',
                  color: net < 0 ? tokens.danger : tokens.success),
            ]),
            const SizedBox(height: 12),
            if (shares.isNotEmpty)
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('分類占比（本月）',
                        style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 6),
                    // 甜甜圈：百分比以**引線**標於圈外（不壓扇區）。
                    CategoryDonut(
                        shares: shares, totalMinor: report.totalMinor),
                    const SizedBox(height: 6),
                    // 色點圖例（名稱 % 金額）——色點與扇區同色（同一索引）。
                    for (final (i, share) in shares.indexed)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                                color: statsPalette[i % statsPalette.length],
                                borderRadius: BorderRadius.circular(3)),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(
                                  '${share.name} ${share.percentText}%',
                                  style: const TextStyle(fontSize: 12))),
                          Text(fmt.format(share.amountMinor),
                              style: const TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                  ],
                ),
              )
          ] else
            // 空狀態（M7 UI 統整——無資料月份引導）。
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                children: [
                  Icon(Icons.query_stats_outlined,
                      size: 40, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 8),
                  const Text('尚無資料——記一筆後這裡會出現統計'),
                ],
              ),
            ),
          const SizedBox(height: 12),
          // 月趨勢（支出）——**白卡**（PM 2026-10-26；原為裸標題）。
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('月趨勢（支出）',
                    style: Theme.of(context).textTheme.labelLarge),
                if (trendKeys.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 150,
                    child:
                        _TrendBarChart(trendKeys: trendKeys, trend: trend),
                  ),
                ],
                for (final k in trendKeys)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Icon(Icons.bar_chart,
                          size: 16, color: AppTokens.of(context).subText),
                      const SizedBox(width: 8),
                      Text('${k.$2}月 ${fmt.format(trend[k]!)}',
                          style: const TextStyle(fontSize: 12)),
                    ]),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 月份列左右鈕（11 雛型 `.mk`：白底圓角外框）。
class _MonthNavButton extends StatelessWidget {
  const _MonthNavButton(
      {super.key,
      required this.icon,
      required this.tooltip,
      required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 36,
          height: 44,
          child: _BorderedBox(
            child: Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          ),
        ),
      ),
    );
  }
}

/// 白底圓角外框容器（月份列／卡片共用；11 雛型）。
class _BorderedBox extends StatelessWidget {
  const _BorderedBox({required this.child, this.padding});
  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      alignment: padding == null ? Alignment.center : null,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

/// 白卡（11-stats 雛型）。
class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color:
                  Theme.of(context).colorScheme.shadow.withValues(alpha: 0.06),
              blurRadius: 3,
              offset: const Offset(0, 1)),
        ],
      ),
      child: child,
    );
  }
}

/// 三卡之一（支出／收入／淨額）——**底色＋外框**（PM 2026-10-26：原僅淡底、無框）。
class _SummaryCard extends StatelessWidget {
  const _SummaryCard(
      {required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: AppTokens.of(context).track,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(children: [
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.outline)),
          const SizedBox(height: 4),
          FittedBox(
              child: Text(value,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: color))),
        ]),
      ),
    );
  }
}

/// 月趨勢長條圖（fl_chart BarChart；觸摸顯示金額 tooltip）。
class _TrendBarChart extends StatelessWidget {
  const _TrendBarChart({required this.trendKeys, required this.trend});

  final List<(int, int)> trendKeys;
  final Map<(int, int), int> trend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BarChart(
      BarChartData(
        gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (v) => FlLine(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
                strokeWidth: 1)),
        borderData: FlBorderData(show: false),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                BarTooltipItem(fmtTrend(rod.toY), TextStyle(color: scheme.onSurface)),
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= trendKeys.length) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${trendKeys[i].$2}月',
                      style: Theme.of(context).textTheme.labelSmall),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (final (i, k) in trendKeys.indexed)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: trend[k]!.toDouble(),
                  color: statsPalette.first,
                  width: 18,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(4)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  static String fmtTrend(double v) {
    final n = v.round();
    return NumberFormat('#,###').format(n);
  }
}
