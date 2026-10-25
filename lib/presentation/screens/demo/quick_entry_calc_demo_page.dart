import 'package:flutter/material.dart';

import '../quick_entry/amount_keypad.dart';
import 'demo_shared.dart';

/// 新增資料（快記 v2）Demo——對映 specs/plan/ui/10-quick-entry-calc.html。
///
/// **可互動**：直接重用正式元件 [AmountKeypad]（S2.9 計算機鍵盤）——
/// 按鍵／運算／**即時求值**／C／⌫ 皆為真實行為（PM 2026-10-24：第一排 C/⌫/OK、
/// 移除＝、＋移位、0 跨兩格）；模式列＝**支出／收入／轉帳**（PM 2026-10-24）。
/// 儲存啟用狀態（S2.1：求值>0）同步呈現。不含資料庫（虛構劇例）。
class QuickEntryCalcDemoContent extends StatefulWidget {
  const QuickEntryCalcDemoContent({super.key});

  @override
  State<QuickEntryCalcDemoContent> createState() =>
      _QuickEntryCalcDemoContentState();
}

class _QuickEntryCalcDemoContentState extends State<QuickEntryCalcDemoContent> {
  String _expr = '120+45';
  String _mode = '支出';
  // PM 2026-10-24：模式列＝**支出／收入／轉帳**（拆分移至明細編輯；預算走預算頁）。
  final _modes = const ['支出', '收入', '轉帳'];

  int? get _amount => AmountKeypadEvaluator.evaluate(_expr);

  bool get _saveEnabled {
    final amount = _amount;
    if (amount == null || amount <= 0) return false;
    // 轉帳/還款需目標帳戶（Demo 固定已選）。
    return true;
  }

  void _onExpr(String expr) => setState(() => _expr = expr);

  @override
  Widget build(BuildContext context) {
    final dark = DemoThemeScope.of(context).dark;
    return Container(
      color: const Color(0xFF12312F),
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: 920,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('✕ 離開',
                        style: TextStyle(color: Color(0xFF9FD4D0), fontSize: 13)),
                    Text('2026/10/20 09:30',
                        style: TextStyle(color: Color(0xFF9FD4D0), fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 12),
                // 模式切換（F02：支出/轉帳；收入/還款 BE 已支援、UI 隨情境擴充）。
                SegmentedButton<String>(
                  segments: [
                    for (final m in _modes)
                      ButtonSegment(value: m, label: Text(m)),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                  style: SegmentedButton.styleFrom(
                    selectedBackgroundColor: const Color(0xFFF5C86B),
                    selectedForegroundColor: const Color(0xFF12312F),
                    backgroundColor: dark ? const Color(0xFF1E2829) : Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                // 金額（運算式顯示；**即時求值**——PM 2026-10-24 移除＝鍵）。
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    children: [
                      Text(
                        _expr.isEmpty ? '0' : _expr,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 36,
                            fontWeight: FontWeight.w800),
                      ),
                      const Text('帳戶：現金（Sticky）· 金額置中（03 雛型）',
                          style:
                              TextStyle(fontSize: 12, color: Color(0xFF9FD4D0))),
                    ],
                  ),
                ),
                // 欄位（轉帳模式 → 來源/目標帳戶；其餘 → 帳戶/分類/商家）。
                if (_mode == '轉帳') ...[
                  const _Field(label: '來源帳戶', value: '銀行'),
                  const _Field(label: '目標帳戶', value: '票證卡（儲值語意）'),
                  const _Field(label: '分類／商家', value: '不適用（轉帳語意）'),
                ] else ...[
                  const _Field(label: '帳戶', value: '現金'),
                  const _Field(label: '分類', value: '餐飲食品'),
                  const _Field(label: '商家', value: '晨光早餐店'),
                ],
                const SizedBox(height: 6),
                // 計算機鍵盤（正式元件——可互動）。
                AmountKeypad(expr: _expr, onExprChanged: _onExpr),
                const SizedBox(height: 8),
                // 儲存（S2.1：純數字>0 啟用；運算式未完成禁用）。
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _saveEnabled ? () {} : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFF5C86B),
                      disabledBackgroundColor:
                          const Color(0xFF9FD4D0).withValues(alpha: 0.18),
                    ),
                    child: Text(
                      _saveEnabled ? '儲存 $_amount 元' : '儲存（完成運算式後啟用）',
                      style: const TextStyle(
                          color: Color(0xFF12312F),
                          fontSize: 17,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '💡 試試：120＋45 即時求值 165／C 清空／⌫ 退位／連按運算子取代；'
                  '未完成式（尾運算子／÷0）→ OK 禁用。轉帳不計收支（AC-10）。',
                  style: TextStyle(fontSize: 11, color: DemoThemeScope.of(context).sub),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Demo 欄位（虛構劇例）。
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFF9FD4D0).withValues(alpha: 0.08),
                border: Border.all(color: const Color(0xFF9FD4D0).withValues(alpha: 0.14)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(fontSize: 13, color: Color(0xFFD9E8E7)),
                  children: [
                    TextSpan(
                        text: '$label\n',
                        style: const TextStyle(
                            fontSize: 10, color: Color(0xFF9FD4D0))),
                    TextSpan(text: value, style: const TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
