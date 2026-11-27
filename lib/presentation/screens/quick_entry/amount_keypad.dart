import 'package:flutter/material.dart';

/// 金額計算機鍵盤（F02 S2.9：常駐四則運算）。
///
/// **版面（PM 2026-10-24 定稿）**
/// ```
/// [C] [⌫] [OK]      ← 第一排＝C／刪除／OK（OK 取代原「＝」的位置與角色）
/// [7] [8] [9] [÷]
/// [4] [5] [6] [×]
/// [1] [2] [3] [－]
/// [   0   ] [.] [＋]  ← 0 跨兩格；＋ 移至原 ⌫ 位置
/// ```
/// - **即時求值顯示**（PM 2026-11-26）：金額欄可求值即顯示結果（50×2→100）。
/// - [onExprChanged]：運算式狀態變更；呼叫端同步顯示與 controller。
/// - **OK／＝ 雙態按鈕**（PM 2026-11-26）：運算式**含運算子**→顯示「＝」
///   （按＝求值收合 50×2→100；key `keypad-equals`）；**純數字**→顯示「OK」
///   （按＝存檔；key `quick-entry-save`）。版面樣式不變，只隨內容變身。
/// - 慣例：首鍵運算子忽略；連按運算子→**取代**前一運算子。
class AmountKeypad extends StatelessWidget {
  const AmountKeypad({
    super.key,
    required this.expr,
    required this.onExprChanged,
    this.onOk,
    this.okEnabled = false,
  });

  /// 當前運算式（如 "120＋45"；狀態由呼叫端持有——本元件受控）。
  final String expr;
  final ValueChanged<String> onExprChanged;

  /// OK 儲存（僅**純數字態**；運算式中此鍵變「＝」——見 [_buildOkEquals]）。
  final VoidCallback? onOk;
  final bool okEnabled;

  static const String _operators = '＋－×÷';

  void _tap(String label) {
    switch (label) {
      case 'C':
        onExprChanged('');
        return;
      case '⌫':
        onExprChanged(expr.isEmpty ? '' : expr.substring(0, expr.length - 1));
        return;
      case '.':
        // 小數點（PM 2026-10-22）：運算子後自動補 0.；同數字 token 內限一個。
        if (expr.isEmpty || _operators.contains(expr[expr.length - 1])) {
          onExprChanged('${expr}0.');
          return;
        }
        final lastNum = expr.split(RegExp(r'[＋－×÷]')).last;
        if (lastNum.contains('.')) return; // 一數一點
        onExprChanged('$expr.');
        return;
      case '＋' || '－' || '×' || '÷':
        if (expr.isEmpty) return; // 首鍵運算子：忽略
        final last = expr[expr.length - 1];
        if (_operators.contains(last)) {
          onExprChanged('${expr.substring(0, expr.length - 1)}$label'); // 連按取代
        } else {
          onExprChanged('$expr$label');
        }
        return;
      default: // 數字
        onExprChanged('$expr$label');
    }
  }

  Widget _key(
    BuildContext context,
    String label, {
    bool primary = false,
    VoidCallback? onTap,
    int flex = 1,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Material(
          // 圓角矩形（10 雛型；PM 2026-10-24：非膠囊）。
          color: primary ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            key: Key('keypad-$label'),
            borderRadius: BorderRadius.circular(12),
            onTap: onTap ?? () => _tap(label),
            child: SizedBox(
              height: 46,
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 19,
                    color: primary ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 第一排第三鍵：**OK／＝ 雙態按鈕**（PM 2026-11-26）。
  ///
  /// - 運算式**含運算子**（計算式中）→ 顯示「＝」：按＝求值收合
  ///   （50×2 → 100，經 [onExprChanged] 寫回；未完成→禁用）。
  /// - **純數字**（無運算子；含空）→ 顯示「OK」：按＝存檔（[onOk]；
  ///   啟用由呼叫端 [okEnabled] 決定）。
  /// 版面不變（跨兩格、樣式同原 OK），只隨運算式內容切換文字與功能。
  Widget _buildOkEquals(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isEqualsMode = expr.contains(RegExp(r'[＋－×÷]'));
    final equalsOk = AmountKeypadEvaluator.evaluate(expr) != null;
    final enabled = isEqualsMode ? equalsOk : okEnabled;
    return Expanded(
      flex: 2,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Material(
          color: enabled ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            key: isEqualsMode
                ? const Key('keypad-equals')
                : const Key('quick-entry-save'),
            borderRadius: BorderRadius.circular(12),
            onTap: !enabled
                ? null
                : isEqualsMode
                ? () {
                    final v = AmountKeypadEvaluator.evaluate(expr);
                    if (v != null) onExprChanged('$v'); // 收合：50×2 → 100
                  }
                : onOk,
            child: SizedBox(
              height: 46,
              child: Center(
                child: Text(
                  isEqualsMode ? '＝' : 'OK',
                  style: TextStyle(
                    fontSize: isEqualsMode ? 19 : 17,
                    fontWeight: FontWeight.w800,
                    color: enabled ? scheme.onPrimary : scheme.outline,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('amount-keypad'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 第一排：C／⌫／OK（**OK／＝ 雙態按鈕**——版面樣式不變，見下）。
          Row(
            children: [
              _key(context, 'C'),
              _key(context, '⌫'),
              _buildOkEquals(context),
            ],
          ),
          for (final row in const [
            ['7', '8', '9', '÷'],
            ['4', '5', '6', '×'],
            ['1', '2', '3', '－'],
          ])
            Row(children: [for (final label in row) _key(context, label)]),
          // 末排：0 跨兩格、小數點、＋（＋ 移至原 ⌫ 位置；＝ 已移除）。
          Row(
            children: [
              _key(context, '0', flex: 2),
              _key(context, '.'),
              _key(context, '＋'),
            ],
          ),
        ],
      ),
    );
  }
}

/// 聚焦滑入／失焦滑出容器（PM 2026-11-26：**所有計算機鍵盤畫面統一互動**）。
///
/// [visible]＝true → 鍵盤由下滑入；false → 向下滑出。
/// 以 `ClipRect`＋`AnimatedAlign(heightFactor 0↔1)` 實作：滑出時**高度同步
/// 收合**（不留空白），滑入時自底部展開——即「由下出現／向下移出」觀感。
/// **包 `TextFieldTapRegion`**（PM 2026-11-26 修）：web 環境點聚焦欄位「外」
/// 會觸發 `onTapOutside` 失焦——按鍵點擊必須視為欄位群組內，否則**每點一鍵
/// 小算盤就收合**。
/// **下滑手勢收起**（PM 2026-11-27）：壓住小算盤向下滑動（位移 ≥32px 或
/// 向下甩 >250px/s）→ [onDragDismiss]——呼叫端失焦對應欄位＝**只收小算盤、
/// 不關視窗**；小算盤收起後，壓住表單向下滑才是 sheet 原本的關閉。
/// null → 不啟用手勢（常駐鍵盤畫面：快記／確認清單／桌面）。
/// 使用處：編輯交易、預算表單（皆聚焦滑入制）。
class FocusSlideKeypad extends StatefulWidget {
  const FocusSlideKeypad({
    super.key,
    required this.visible,
    required this.child,
    this.onDragDismiss,
  });

  final bool visible;
  final Widget child;

  /// 壓住小算盤向下滑動 → 只收小算盤、不關視窗（PM 2026-11-27）。
  final VoidCallback? onDragDismiss;

  @override
  State<FocusSlideKeypad> createState() => _FocusSlideKeypadState();
}

class _FocusSlideKeypadState extends State<FocusSlideKeypad> {
  static const double _dismissDy = 32; // 向下位移門檻（px）。
  double _dragDy = 0;

  void _onDragUpdate(DragUpdateDetails d) => _dragDy += d.delta.dy;

  void _onDragEnd(DragEndDetails d) {
    final dismiss =
        widget.visible &&
        (_dragDy >= _dismissDy || (d.primaryVelocity ?? 0) > 250);
    _dragDy = 0;
    if (dismiss) widget.onDragDismiss?.call();
  }

  @override
  Widget build(BuildContext context) {
    final onDragDismiss = widget.onDragDismiss;
    return TextFieldTapRegion(
      child: ClipRect(
        child: AnimatedAlign(
          alignment: Alignment.bottomCenter,
          heightFactor: widget.visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: onDragDismiss == null
              ? widget.child
              : GestureDetector(
                  onVerticalDragUpdate: _onDragUpdate,
                  onVerticalDragEnd: _onDragEnd,
                  child: widget.child,
                ),
        ),
      ),
    );
  }
}

/// 運算式求值（純函數；F02 S2.9）。
///
/// 左至右、**無運算子優先權**（計算機慣例，如 2×30＋10 = (2×30)＋10 = 70）；
/// 結果四捨五入至整數（TWD 無小數位，S2.1 邊界）。無效運算式回 null：
/// 空、尾運算子、÷0、非法字元——**即時求值**（PM 2026-10-24 移除 ＝ 鍵：
/// 未完成／無效 → 金額未定 → OK 禁用）。
class AmountKeypadEvaluator {
  AmountKeypadEvaluator._();

  static final _tokenRegex = RegExp(r'\d+(?:\.\d+)?|\.\d+|[＋－×÷]');

  static int? evaluate(String expr) {
    if (expr.isEmpty) return null;
    if (AmountKeypad._operators.contains(expr[expr.length - 1])) return null;
    final tokens = _tokenRegex
        .allMatches(expr)
        .map((m) => m.group(0)!)
        .toList();
    if (tokens.join() != expr) return null; // 非法字元
    if (tokens.isEmpty || tokens.length % 2 == 0) return null; // 數字(運算子數字)*
    var acc = num.parse(tokens[0]);
    for (var i = 1; i < tokens.length; i += 2) {
      final operand = num.parse(tokens[i + 1]);
      switch (tokens[i]) {
        case '＋':
          acc += operand;
        case '－':
          acc -= operand;
        case '×':
          acc *= operand;
        case '÷':
          if (operand == 0) return null;
          acc /= operand;
      }
    }
    return acc.round();
  }

  /// 金額欄顯示文字（PM 2026-11-26：**即時求值顯示**）——
  /// 運算式可求值 → 顯示**結果**（例：50×2 → `100`）；未完成（空／尾運算子／
  /// 非法字元）→ 顯示輸入中原式。**存檔前即可確認金額是否正確**（PM 指示：
  /// 「50×2 要顯示 100，不是按 OK 才知道」）。編輯狀態仍為原運算式——
  /// ⌫ 回修運算式、C 清空，顯示隨之更新。
  static String display(String expr) {
    final v = evaluate(expr);
    return v == null ? expr : '$v';
  }
}
