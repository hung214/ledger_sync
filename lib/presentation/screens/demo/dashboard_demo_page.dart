import 'package:flutter/material.dart';

import 'demo_shared.dart';

/// 總覽畫面 Demo（對映 specs/plan/ui/01-dashboard.html；資料 = 虛構劇例）。
class DashboardDemoContent extends StatelessWidget {
  const DashboardDemoContent({super.key});

  @override
  Widget build(BuildContext context) {
    final t = DemoThemeScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 84),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('總覽',
                    style: TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold, color: t.text)),
                const Row(children: [
                  Icon(Icons.visibility_outlined, size: 20, color: Color(0xFF7D8B8A)),
                  SizedBox(width: 8),
                  _ScanButton(),
                ]),
              ],
            ),
          ),
          const SizedBox(height: 14),
          DemoCard(
            title: '本月收支（10 月）',
            child: Column(children: [
              const _AmountRow('支出', '−12,340', DemoTheme.red),
              const SizedBox(height: 6),
              const _AmountRow('收入', '+62,000', DemoTheme.green),
              const SizedBox(height: 6),
              _AmountRow('結餘', '49,660', t.text),
            ]),
          ),
          const Row(children: [
            SizedBox(width: 16),
            Expanded(child: _StatCard(label: '資產', value: '41,000')),
            SizedBox(width: 8),
            Expanded(
                child: _StatCard(
                    label: '負債', value: '8,000', valueColor: DemoTheme.red)),
            SizedBox(width: 8),
            Expanded(child: _StatCard(label: '淨值', value: '33,000')),
            SizedBox(width: 16),
          ]),
          const SizedBox(height: 12),
          DemoCard(
            title: '本月預計結餘（FR-B7）',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _AmountRow('收入目標 60,000 − 總預算 30,000', '30,000', DemoTheme.green),
                const SizedBox(height: 6),
                _Note('實際結餘 49,660（含信用卡預扣）'),
              ],
            ),
          ),
          DemoCard(
            title: '預算摘要',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('餐飲食品',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: t.text)),
                    const Text('7,000 / 8,000（87.5%）',
                        style: TextStyle(
                            fontSize: 12,
                            color: DemoTheme.amber,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 8),
                const DemoBar(ratio: 0.875, color: DemoTheme.amber),
                const SizedBox(height: 8),
                const _Note('⚠ 已達 80% 警告門檻（N-1 已發送一次）'),
              ],
            ),
          ),
          DemoCard(
            title: '收入目標',
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                  color: const Color(0xFFE6F4F3),
                  borderRadius: BorderRadius.circular(10)),
              child: const Text('已達成 103%',
                  style: TextStyle(
                      fontSize: 11,
                      color: DemoTheme.teal,
                      fontWeight: FontWeight.w600)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    const Text('62,000',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: DemoTheme.green)),
                    const SizedBox(width: 6),
                    Text('/ 目標 60,000',
                        style: TextStyle(fontSize: 12, color: t.sub)),
                  ],
                ),
                const SizedBox(height: 8),
                const DemoBar(ratio: 1),
              ],
            ),
          ),
          DemoCard(
            title: '最近交易',
            child: const Column(children: [
              DemoTxTile(
                  icon: Icons.shopping_basket_outlined,
                  title: '陽光超商',
                  subtitle: '今天 09:12 · 現金 · 服飾美容 · 掃描',
                  amount: -195,
                  hasAttachment: true),
              DemoTxTile(
                  icon: Icons.bakery_dining_outlined,
                  title: '晨光早餐店',
                  subtitle: '今天 08:15 · 現金 · 餐飲食品',
                  amount: -120),
              DemoTxTile(
                  icon: Icons.credit_card,
                  title: '信用卡繳款',
                  subtitle: '昨天 · 薪轉 → 示例卡 · 已繳',
                  amount: 5000),
            ]),
          ),
        ],
      ),
    );
  }
}

class _ScanButton extends StatelessWidget {
  const _ScanButton();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration:
          BoxDecoration(color: DemoTheme.teal, borderRadius: BorderRadius.circular(10)),
      child: const Row(children: [
        Icon(Icons.photo_camera_outlined, size: 14, color: Colors.white),
        SizedBox(width: 4),
        Text('掃描',
            style: TextStyle(
                color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow(this.label, this.value, [this.color]);
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = DemoThemeScope.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: t.sub)),
        Text(value,
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.bold, color: color ?? t.text)),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard(
      {required this.label, required this.value, this.valueColor = const Color(0xFF1C2B2A)});
  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    final t = DemoThemeScope.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 4)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: t.sub)),
          const SizedBox(height: 4),
          Text(value,
              style:
                  TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: valueColor)),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = DemoThemeScope.of(context);
    return Text(text, style: TextStyle(fontSize: 11, color: t.faint));
  }
}
