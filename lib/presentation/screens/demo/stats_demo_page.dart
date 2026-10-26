import 'package:flutter/material.dart';

import '../../../application/reports/report_service.dart';
import '../stats/category_donut.dart';
import 'demo_shared.dart';

/// 統計 DEMO（PM 2026-10-24：**新增**——對齊 `specs/plan/ui/11-stats.html`）。
/// 虛構劇例：本月 支出 12,340／收入 62,000；占比 餐飲 46%／購物 26%／交通 16%／居住 12%。
class StatsDemoContent extends StatelessWidget {
  const StatsDemoContent({super.key});

  static const _data = [
    ('🍜 餐飲食品', 46.0, '5,700', Color(0xFF0B7A75)),
    ('🛒 購物', 26.0, '3,200', Color(0xFFF5C86B)),
    ('🚇 交通運輸', 16.0, '2,000', Color(0xFF6D4FC4)),
    ('🏠 居住', 12.0, '1,440', Color(0xFFD64545)),
  ];

  @override
  Widget build(BuildContext context) {
    final t = DemoThemeScope.of(context);
    return DemoPageShell(
      title: '11 統計',
      spec: 'specs/plan/ui/11-stats.html',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('統計',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          // 月份列：◀ 期間 ▾ ▶
          Row(children: [
            const _MK(icon: '‹'),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: t.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: t.line),
                ),
                child: Column(children: [
                  Text('2026/10',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: t.text)),
                  Text('期間（月份）',
                      style: TextStyle(fontSize: 10, color: t.faint)),
                ]),
              ),
            ),
            const _MK(icon: '›'),
          ]),
          const SizedBox(height: 12),
          // 三卡：支出／收入／淨額
          const Row(children: [
            Expanded(
                child: _Sum(
                    label: '支出', value: '-12,340', color: Color(0xFFD64545))),
            SizedBox(width: 8),
            Expanded(
                child: _Sum(
                    label: '收入', value: '+62,000', color: Color(0xFF0B7A75))),
            SizedBox(width: 8),
            Expanded(
                child: _Sum(
                    label: '淨額', value: '+49,660', color: Color(0xFF0B7A75))),
          ]),
          const SizedBox(height: 12),
          DemoCard(
            title: '分類占比（本月）',
            child: Column(children: [
              // PM 2026-10-26：共用甜甜圈（百分比**圈外引線**；固定色板）。
              CategoryDonut(
                height: 200,
                totalMinor: 12340,
                shares: [
                  for (final d in _data)
                    CategoryShare(
                        name: d.$1,
                        amountMinor:
                            int.parse(d.$3.replaceAll(',', '')),
                        percentText: d.$2.toStringAsFixed(0)),
                ],
              ),
              const SizedBox(height: 8),
              for (final (name, pct, amount, color) in _data)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                            color: statsPalette[
                                _data.indexWhere((d) => d.$4 == color) %
                                    statsPalette.length],
                            borderRadius: BorderRadius.circular(4))),
                    const SizedBox(width: 8),
                    Expanded(
                        child:
                            Text(name, style: const TextStyle(fontSize: 12))),
                    Text('$pct%',
                        style: TextStyle(
                            fontSize: 11, color: t.faint)),
                    const SizedBox(width: 10),
                    Text(amount,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700)),
                  ]),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          DemoCard(
            title: '月趨勢（支出）',
            child: SizedBox(
              height: 110,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final (m, ratio) in const [
                    ('8月', .40),
                    ('9月', .62),
                    ('10月', 1.0)
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              height: 90 * ratio,
                              decoration: BoxDecoration(
                                color: DemoTheme.teal,
                                borderRadius: BorderRadius.vertical(
                                    top: Radius.circular(6)),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(m,
                                style: TextStyle(
                                    fontSize: 10, color: t.faint)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const _Note('① 月份列：◀ 期間 ▾ ▶（預設本月）②三卡：支出／收入／淨額 '
              '③占比＝甜甜圈＋色點圖例 ④金額千分位、支出紅／收入綠'),
        ],
      ),
      ),
    );
  }
}

class _MK extends StatelessWidget {
  const _MK({required this.icon});
  final String icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: DemoThemeScope.of(context).card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DemoThemeScope.of(context).line),
      ),
      child: Text(icon,
          style: const TextStyle(fontSize: 16, color: DemoTheme.teal)),
    );
  }
}

class _Sum extends StatelessWidget {
  const _Sum({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
      decoration: BoxDecoration(
        // 底色＋外框（PM 2026-10-26：原僅白底無框，風格不符）。
        color: DemoThemeScope.of(context).track,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DemoThemeScope.of(context).line),
      ),
      child: Column(children: [
        Text(label,
            style: TextStyle(
                fontSize: 10, color: DemoThemeScope.of(context).faint)),
        const SizedBox(height: 3),
        Text(value,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w800, color: color)),
      ]),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text('• $text',
          style: TextStyle(
              fontSize: 11, color: DemoThemeScope.of(context).faint)),
    );
  }
}
