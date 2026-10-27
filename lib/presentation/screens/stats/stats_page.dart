import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../../application/providers.dart';
import '../../../application/reports/report_service.dart';
import '../../theme/app_theme.dart';
import 'category_donut.dart';

/// 統計指標（PM 2026-10-27：三卡＝**可點選切換**，圓餅與月趨勢連動）。
///
/// [cumulative]＝**累計結餘**（到選定月份為止的累計收支結餘）——PM 2026-10-27：
/// **資料有 2 個月以上**才提供此選項。
enum StatsMetric { expense, income, net, cumulative }

/// 月趨勢顯示上限（PM 2026-10-27：**最多最近 12 個月**）。
const int statsTrendMonths = 12;

/// 統計頁（FR-R2 呈現面；v4——PM 2026-10-26 整頁重做、PM 2026-10-27 可切換指標）。
///
/// - **月份列**：`◀`／`2026/10`＋小字「期間（月份）」／`▶`（皆白底圓角外框）。
/// - **三卡**：支出／收入／淨額——**底色＋外框**，**可點選**（選中＝primary 強調）；
///   選擇後**分類占比與月趨勢一併切換**。
/// - **分類占比**（支出／收入）＝**依主類別彙總**＋甜甜圈（百分比**圈外引線**）＋色點圖例；
///   **淨額**＝「收支組成」（收入／支出兩塊；圓心＝淨額）。
/// - **月趨勢**＝白卡＋長條；淨額可為負（負值紅、0 基準線）。
/// - 既有數值文字契約不變（`合計`／`{名稱} {pct}%`／`{m}月 {總計}`）。
class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key});

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends ConsumerState<StatsPage> {
  (int, int)? _selected; // (year, month)；null = 最新有資料月份
  StatsMetric _metric = StatsMetric.expense;

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

  String get _metricLabel => switch (_metric) {
        StatsMetric.expense => '支出',
        StatsMetric.income => '收入',
        StatsMetric.net => '淨額',
        StatsMetric.cumulative => '累計結餘',
      };

  @override
  Widget build(BuildContext context) {
    ref.watch(ledgerProvider); // 交易變化即時刷新
    final db = ref.watch(dbProvider);
    final fmt = NumberFormat('#,###');
    final tokens = AppTokens.of(context);

    // 期間選單／趨勢的月份來源＝**所有未刪除交易**（含收入；PM 2026-10-27）。
    final allTxs =
        db.allTransactions().where((t) => t.deletedAt == null).toList();
    (int, int) keyOf(int ms) {
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      return (d.year, d.month);
    }

    // 月份清單（新→舊）——DBG-015：原比較子誤寫 `b.$2.compareTo(b.$2)`（自我比較
    // 恆 0）→ 清單未排序 → **預設月份可能不是最新月**。
    final months = allTxs.map((t) => keyOf(t.occurredAt)).toSet().toList()
      ..sort((a, b) => b.$1.compareTo(a.$1) != 0
          ? b.$1.compareTo(a.$1)
          : b.$2.compareTo(a.$2));
    final selected = _selected ?? (months.isEmpty ? null : months.first);

    final expenseTrend = <(int, int), int>{};
    final incomeTrend = <(int, int), int>{};
    for (final t in allTxs) {
      final k = keyOf(t.occurredAt);
      if (t.kind == 'expense') {
        expenseTrend[k] = (expenseTrend[k] ?? 0) + t.amountMinor;
      } else if (t.kind == 'income') {
        incomeTrend[k] = (incomeTrend[k] ?? 0) + t.amountMinor;
      }
    }
    final trendKeys = {...expenseTrend.keys, ...incomeTrend.keys}.toList()
      ..sort((a, b) => a.$1.compareTo(b.$1) != 0
          ? a.$1.compareTo(b.$1)
          : a.$2.compareTo(b.$2));
    final netTrend = {
      for (final k in trendKeys) k: (incomeTrend[k] ?? 0) - (expenseTrend[k] ?? 0)
    };
    // 累計結餘（升冪累加；月份清單本身只含「有資料的月份」）。
    final cumulativeTrend = <(int, int), int>{};
    var running = 0;
    for (final k in trendKeys) {
      running += netTrend[k] ?? 0;
      cumulativeTrend[k] = running;
    }
    // 累計結餘選項：**資料 2 個月以上**才提供（PM 2026-10-27）。
    final showCumulative = trendKeys.length >= 2;
    if (_metric == StatsMetric.cumulative && !showCumulative) {
      _metric = StatsMetric.expense;
    }
    final trend = switch (_metric) {
      StatsMetric.expense => expenseTrend,
      StatsMetric.income => incomeTrend,
      StatsMetric.net => netTrend,
      StatsMetric.cumulative => cumulativeTrend,
    };
    // 顯示視窗＝**最近 12 個月**（PM 2026-10-27）；下方明細列同步。
    final windowKeys = trendKeys.length <= statsTrendMonths
        ? trendKeys
        : trendKeys.sublist(trendKeys.length - statsTrendMonths);
    // 選定月份的**累計**收支（累計結餘檢視的占比＝期間至該月為止）。
    var cumIncome = 0;
    var cumExpense = 0;
    for (final k in trendKeys) {
      cumIncome += incomeTrend[k] ?? 0;
      cumExpense += expenseTrend[k] ?? 0;
      if (selected != null && k == selected) break;
    }
    final cumulativeBalance = cumIncome - cumExpense;

    final expenseTotal = selected == null ? 0 : (expenseTrend[selected] ?? 0);
    final incomeTotal = selected == null ? 0 : (incomeTrend[selected] ?? 0);
    final net = incomeTotal - expenseTotal;

    // 占比資料：支出／收入＝該 kind 之主類別彙總；淨額＝收支組成（兩塊）。
    final svc = ReportService(db);
    List<CategoryShare> shares = const [];
    var sharesTotal = 0;
    if (selected != null) {
      if (_metric == StatsMetric.net || _metric == StatsMetric.cumulative) {
        // 淨額＝**當月**收支組成；累計結餘＝**至選定月為止**的收支組成。
        final inc = _metric == StatsMetric.cumulative ? cumIncome : incomeTotal;
        final exp = _metric == StatsMetric.cumulative ? cumExpense : expenseTotal;
        final sum = inc.abs() + exp.abs();
        String pct(int v) =>
            sum <= 0 ? '0.0' : (v.abs() * 100 / sum).toStringAsFixed(1);
        shares = [
          if (inc != 0)
            CategoryShare(
                name: '收入',
                amountMinor: inc.abs(),
                percentText: pct(inc)),
          if (exp != 0)
            CategoryShare(
                name: '支出',
                amountMinor: exp.abs(),
                percentText: pct(exp)),
        ]..sort((a, b) => b.amountMinor.compareTo(a.amountMinor));
        sharesTotal = sum;
      } else {
        final r = svc.aggregateByMain(selected.$1, selected.$2,
            kind: _metric == StatsMetric.income ? 'income' : 'expense');
        shares = r.shares.where((s) => s.amountMinor > 0).toList();
        sharesTotal = r.totalMinor;
      }
    }

    // 扇區／圖例**同一來源**（淨額檢視＝收入綠／支出紅；其餘＝statsPalette）。
    final composition =
        _metric == StatsMetric.net || _metric == StatsMetric.cumulative;
    final donutColors = composition
        ? [
            for (final sh in shares)
              sh.name == '收入' ? tokens.success : tokens.danger,
          ]
        : null;
    Color colorAt(int i) => donutColors != null && i < donutColors.length
        ? donutColors[i]
        : statsPalette[i % statsPalette.length];

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
          if (selected != null) ...[
            // 三卡：支出／收入／淨額——**可點選切換**（PM 2026-10-27；選中＝primary 強調）。
            Row(children: [
              _SummaryCard(
                  key: const Key('stats-metric-支出'),
                  label: '支出',
                  value: '-${fmt.format(expenseTotal)}',
                  color: tokens.danger,
                  selected: _metric == StatsMetric.expense,
                  onTap: () => setState(() => _metric = StatsMetric.expense)),
              const SizedBox(width: 8),
              _SummaryCard(
                  key: const Key('stats-metric-收入'),
                  label: '收入',
                  value: '+${fmt.format(incomeTotal)}',
                  color: tokens.success,
                  selected: _metric == StatsMetric.income,
                  onTap: () => setState(() => _metric = StatsMetric.income)),
              const SizedBox(width: 8),
              _SummaryCard(
                  key: const Key('stats-metric-淨額'),
                  label: '淨額',
                  value: '${net < 0 ? '-' : ''}${fmt.format(net.abs())}',
                  color: net < 0 ? tokens.danger : tokens.success,
                  selected: _metric == StatsMetric.net,
                  onTap: () => setState(() => _metric = StatsMetric.net)),
              // 累計結餘（PM 2026-10-27：**2 個月以上**才出現）。
              if (showCumulative) ...[
                const SizedBox(width: 8),
                _SummaryCard(
                    key: const Key('stats-metric-累計結餘'),
                    label: '累計結餘',
                    value:
                        '${cumulativeBalance < 0 ? '-' : ''}${fmt.format(cumulativeBalance.abs())}',
                    color: cumulativeBalance < 0
                        ? tokens.danger
                        : tokens.success,
                    selected: _metric == StatsMetric.cumulative,
                    onTap: () =>
                        setState(() => _metric = StatsMetric.cumulative)),
              ],
            ]),
            const SizedBox(height: 12),
            if (shares.isNotEmpty)
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        switch (_metric) {
                          StatsMetric.net => '收支組成（本月）',
                          StatsMetric.cumulative => '收支組成（累計）',
                          _ => '分類占比（本月）',
                        },
                        style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 6),
                    // 甜甜圈：百分比以**引線**標於圈外（不壓扇區）；
                    // 淨額檢視＝圓心顯示「淨額」與其值。
                    CategoryDonut(
                      shares: shares,
                      totalMinor: sharesTotal,
                      centerLabel: switch (_metric) {
                        StatsMetric.net => '淨額',
                        StatsMetric.cumulative => '累計結餘',
                        _ => '合計',
                      },
                      centerText: switch (_metric) {
                        StatsMetric.net =>
                          '${net < 0 ? '-' : '+'}${fmt.format(net.abs())}',
                        StatsMetric.cumulative =>
                          '${cumulativeBalance < 0 ? '-' : '+'}${fmt.format(cumulativeBalance.abs())}',
                        _ => null,
                      },
                      // 淨額檢視＝兩塊：語意色（收入綠／支出紅）；與圖例同來源。
                      colors: donutColors,
                    ),
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
                                color: colorAt(i),
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
            else
              _Card(
                child: Text('本月無$_metricLabel資料',
                    style: Theme.of(context).textTheme.labelLarge),
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
          // 月趨勢——**跟隨所選指標**（支出／收入／淨額；PM 2026-10-27）。
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('月趨勢（$_metricLabel）',
                    style: Theme.of(context).textTheme.labelLarge),
                if (trendKeys.length > statsTrendMonths)
                  Text('僅顯示最近 $statsTrendMonths 個月（共 ${trendKeys.length} 個月）',
                      style: TextStyle(fontSize: 10, color: tokens.subText)),
                if (windowKeys.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 150,
                    child: _TrendBarChart(
                        trendKeys: windowKeys,
                        trend: trend,
                        signed: composition),
                  ),
                ],
                for (final k in windowKeys)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Icon(Icons.bar_chart, size: 16, color: tokens.subText),
                      const SizedBox(width: 8),
                      Text(
                          '${k.$2}月 ${_signed(trend[k] ?? 0, _metric == StatsMetric.net, fmt)}',
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

  /// 趨勢列數值：淨額帶正負號（支出／收入為原值）。
  static String _signed(int v, bool signed, NumberFormat fmt) => signed
      ? '${v < 0 ? '-' : ''}${fmt.format(v.abs())}'
      : fmt.format(v);
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
            child: Icon(icon,
                size: 18, color: Theme.of(context).colorScheme.primary),
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

/// 三卡之一（支出／收入／淨額）——**底色＋外框**、**可點選切換**（PM 2026-10-27）。
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String value;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AppTokens.of(context);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer : tokens.track,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 1.6 : 1),
          ),
          child: Column(children: [
            Text(label,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(
                        color: selected ? scheme.primary : scheme.outline,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.normal)),
            const SizedBox(height: 4),
            FittedBox(
                child: Text(value,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: color))),
          ]),
        ),
      ),
    );
  }
}

/// 月趨勢長條圖（fl_chart BarChart；觸摸顯示金額 tooltip）。
///
/// [signed]＝淨額檢視：可為**負值**（負值紅、設 0 基準線）。
class _TrendBarChart extends StatelessWidget {
  const _TrendBarChart(
      {required this.trendKeys, required this.trend, this.signed = false});

  final List<(int, int)> trendKeys;
  final Map<(int, int), int> trend;
  final bool signed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final values = [for (final k in trendKeys) (trend[k] ?? 0)];
    final maxV = values.isEmpty ? 0 : values.reduce(math.max);
    final minV = values.isEmpty ? 0 : values.reduce(math.min);
    return BarChart(
      BarChartData(
        maxY: maxV <= 0 ? 0 : maxV * 1.15,
        minY: minV < 0 ? minV * 1.15 : 0,
        gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (v) => FlLine(
                // 0 基準線（淨額可負）加粗。
                color: (signed && v == 0)
                    ? scheme.outline
                    : scheme.outlineVariant.withValues(alpha: 0.4),
                strokeWidth: (signed && v == 0) ? 1.4 : 1)),
        borderData: FlBorderData(show: false),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                BarTooltipItem(fmtTrend(rod.toY),
                    TextStyle(color: scheme.onSurface)),
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= trendKeys.length) {
                  return const SizedBox.shrink();
                }
                // 標籤稀疏化（PM 2026-10-27）：月數多時每隔 step 個月標一次，
                // 避免 12 個月標籤擠成一團（其餘月份仍可由下方明細列辨識）。
                final step = (trendKeys.length / 8).ceil();
                if (step > 1 && i % step != 0 &&
                    i != trendKeys.length - 1) {
                  return const SizedBox.shrink();
                }
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
                  toY: (trend[k] ?? 0).toDouble(),
                  color: (signed && (trend[k] ?? 0) < 0)
                      ? AppTokens.of(context).danger
                      : statsPalette.first,
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
