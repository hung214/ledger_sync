import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/presentation/screens/quick_entry/amount_keypad.dart';

/// 計算機鍵盤（F02 S2.9）：求值器純函數＋鍵盤互動慣例。
void main() {
  group('AmountKeypadEvaluator（左至右、無優先權、TWD 四捨五入）', () {
    test('基本四則', () {
      expect(AmountKeypadEvaluator.evaluate('120＋45'), 165);
      expect(AmountKeypadEvaluator.evaluate('500－80'), 420);
      expect(AmountKeypadEvaluator.evaluate('100÷4'), 25);
      expect(AmountKeypadEvaluator.evaluate('12×30'), 360);
    });

    test('左至右無優先權（計算機慣例）：2×30＋10 = 70', () {
      expect(AmountKeypadEvaluator.evaluate('2×30＋10'), 70);
      expect(AmountKeypadEvaluator.evaluate('10＋2×3'), 36); // (10＋2)×3
    });

    test('四捨五入至整數元（TWD 無小數位，S2.1 邊界）', () {
      expect(AmountKeypadEvaluator.evaluate('100÷3'), 33);
      expect(AmountKeypadEvaluator.evaluate('5÷2'), 3); // 2.5 → 3
    });

    test('無效運算式 → null（＝ 保持原式不可儲存）', () {
      expect(AmountKeypadEvaluator.evaluate(''), isNull);
      expect(AmountKeypadEvaluator.evaluate('120＋'), isNull); // 尾運算子
      expect(AmountKeypadEvaluator.evaluate('100÷0'), isNull); // ÷0
      expect(AmountKeypadEvaluator.evaluate('1a2'), isNull); // 非法字元
    });

    test('純數字＝原值', () {
      expect(AmountKeypadEvaluator.evaluate('120'), 120);
      expect(AmountKeypadEvaluator.evaluate('0'), 0);
    });

    test('小數點（PM 2026-10-22）：.5 簡寫／結果四捨五入至整數元', () {
      expect(AmountKeypadEvaluator.evaluate('.5'), 1); // 0.5 → 1（round）
      expect(AmountKeypadEvaluator.evaluate('99.5＋0.5'), 100);
      expect(AmountKeypadEvaluator.evaluate('1.2×3'), 4); // 3.6 → 4
      expect(AmountKeypadEvaluator.evaluate('1.2.3'), isNull); // 非法
    });
  });

  testWidgets('鍵盤互動：數字／連按運算子取代／⌫／C（無＝鍵；PM 2026-10-24）', (tester) async {
    var expr = '';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => AmountKeypad(
            expr: expr,
            onExprChanged: (e) => setState(() => expr = e),
          ),
        ),
      ),
    ));

    Future<void> tap(String label) async {
      await tester.tap(find.byKey(Key('keypad-$label')));
      await tester.pump();
    }

    await tap('＋');
    expect(expr, isEmpty, reason: '首鍵運算子：忽略');
    await tap('1');
    await tap('2');
    await tap('0');
    expect(expr, '120');
    await tap('＋');
    expect(expr, '120＋');
    await tap('×');
    expect(expr, '120×', reason: '連按運算子 → 取代前一運算子');
    await tap('4');
    expect(expr, '120×4');
    // 無「＝」鍵（PM 2026-10-24）：運算式由呼叫端**即時求值**——
    // 完整式（不尾運算子／非 ÷0）→ 求值得值；未完成 → null（OK 禁用）。
    expect(AmountKeypadEvaluator.evaluate(expr), 480);
    await tap('⌫');
    expect(expr, '120×');
    expect(AmountKeypadEvaluator.evaluate(expr), isNull, reason: '尾運算子→未定');
    await tap('C');
    expect(expr, isEmpty);
  });

  testWidgets('鍵盤版面（PM 2026-10-24）：第一排 C／⌫／OK；0 跨兩格；無＝鍵', (tester) async {
    var expr = '';
    var okTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => AmountKeypad(
            expr: expr,
            okEnabled: true,
            onOk: () => okTaps++,
            onExprChanged: (e) => setState(() => expr = e),
          ),
        ),
      ),
    ));
    expect(find.byKey(const Key('keypad-＝')), findsNothing, reason: '＝ 已移除');
    expect(find.byKey(const Key('quick-entry-save')), findsOneWidget,
        reason: 'OK 於鍵盤第一排（key 沿用）');
    expect(find.text('C'), findsOneWidget);
    expect(find.text('⌫'), findsOneWidget);
    await tester.tap(find.byKey(const Key('keypad-0')));
    await tester.pump();
    expect(expr, '0');
    await tester.tap(find.byKey(const Key('quick-entry-save')));
    expect(okTaps, 1, reason: 'OK 觸發儲存回呼');
  });

  testWidgets('雙態按鈕：含運算子→＝，tap 求值收合（50×2→100；PM 2026-11-26）', (tester) async {
    var expr = '50×2';
    String? writtenBack;
    var okTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => AmountKeypad(
            expr: expr,
            okEnabled: true,
            onOk: () => okTaps++,
            onExprChanged: (e) => setState(() {
              expr = e;
              writtenBack = e;
            }),
          ),
        ),
      ),
    ));

    expect(find.text('＝'), findsOneWidget, reason: '運算式含運算子 → ＝ 態');
    expect(find.byKey(const Key('keypad-equals')), findsOneWidget);
    expect(find.text('OK'), findsNothing, reason: '計算式態無 OK');
    await tester.tap(find.byKey(const Key('keypad-equals')));
    await tester.pump();
    expect(writtenBack, '100', reason: '＝ 求值收合：50×2 → 100 經 onExprChanged 寫回');
    expect(okTaps, 0, reason: '＝ 態不觸發儲存');
    expect(find.text('OK'), findsOneWidget, reason: '收合後 100 為純數字 → 回 OK 態');
  });

  testWidgets('雙態按鈕：未完成運算式→＝禁用（尾運算子 50×；PM 2026-11-26）', (tester) async {
    String? writtenBack;
    var okTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AmountKeypad(
          expr: '50×',
          okEnabled: true,
          onOk: () => okTaps++,
          onExprChanged: (e) => writtenBack = e,
        ),
      ),
    ));

    expect(find.text('＝'), findsOneWidget);
    await tester.tap(find.byKey(const Key('keypad-equals')));
    await tester.pump();
    expect(writtenBack, isNull, reason: '尾運算子不可求值 → ＝ 禁用');
    expect(okTaps, 0, reason: '禁用態不觸發儲存');
  });

  testWidgets('雙態按鈕：純數字→OK（key 沿用 quick-entry-save；PM 2026-11-26）', (tester) async {
    String? writtenBack;
    var okTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AmountKeypad(
          expr: '100',
          okEnabled: true,
          onOk: () => okTaps++,
          onExprChanged: (e) => writtenBack = e,
        ),
      ),
    ));

    expect(find.text('OK'), findsOneWidget, reason: '純數字（無運算子）→ OK 態');
    expect(find.byKey(const Key('quick-entry-save')), findsOneWidget);
    expect(find.text('＝'), findsNothing, reason: '純數字態無 ＝');
    await tester.tap(find.byKey(const Key('quick-entry-save')));
    await tester.pump();
    expect(okTaps, 1, reason: 'OK 觸發儲存回呼');
    expect(writtenBack, isNull, reason: 'OK 態不寫回運算式');
  });
}
