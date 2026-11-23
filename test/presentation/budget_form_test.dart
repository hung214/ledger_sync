import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/first_run_bootstrap.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/presentation/screens/budget/budget_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';

/// 預算表單（2026-10-22 補全）快速護欄：App 內建立/編輯/刪除——
/// 總預算／分類預算／收入目標三型（FR-B2/B3/B6）。
/// **跑在純 Dart VM（~1 秒）**——同批斷言若走 integration_test 需 ~15 秒
/// （PM 2026-10-22：前後端測試分流以縮短回饋迴圈）。
void main() {
  testWidgets('預算表單：總預算建立→分類預算→收入目標→編輯→刪除', (tester) async {
    final db = DbFixture.create();
    await FirstRunBootstrap.seedIfNeeded(db);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light), home: const BudgetPage()),
      ));
      await tester.pumpAndSettle();

      // 空狀態引導。
      expect(find.textContaining('尚無預算'), findsOneWidget);

      // ── 1. 總預算：30,000 / 起始日 1 ──
      await tester.tap(find.byKey(const Key('budget-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('budget-amount')), '30000');
      await tester.enterText(find.byKey(const Key('budget-start-day')), '1');
      await tester.tap(find.byKey(const Key('budget-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('budget-total-card')), findsOneWidget);
      expect(find.text('/ 30,000'), findsOneWidget, reason: '總預算卡額度');

      // ── 2. 分類預算：餐飲食品 8,000 ──
      await tester.tap(find.byKey(const Key('budget-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('分類預算')); // Segmented 切換
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('budget-amount')), '8000');
      await tester.enterText(find.byKey(const Key('budget-start-day')), '1');
      await tester.tap(find.byKey(const Key('budget-save')));
      await tester.pumpAndSettle();
      expect(find.text('餐飲食品（含子類）'), findsOneWidget,
          reason: '分類預算項（T71——主分類預算標示含子類加總）');
      expect(find.text('0 / 8,000'), findsOneWidget, reason: '無交易→用量 0/額度');

      // ── 3. 收入目標：60,000 ──
      await tester.tap(find.byKey(const Key('budget-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收入目標')); // Segmented 切換
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('budget-amount')), '60000');
      await tester.enterText(find.byKey(const Key('budget-start-day')), '1');
      await tester.tap(find.byKey(const Key('budget-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('budget-income-card')), findsOneWidget);
      expect(find.text('/ 目標 60,000'), findsOneWidget, reason: '收入目標卡');

      // ── 4. 編輯總預算：點卡→改 35,000 ──
      await tester.tap(find.byKey(const Key('budget-total-card')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '30000'), findsOneWidget,
          reason: '編輯預填原額度');
      await tester.enterText(find.byKey(const Key('budget-amount')), '35000');
      await tester.tap(find.byKey(const Key('budget-save')));
      await tester.pumpAndSettle();
      expect(find.text('/ 35,000'), findsOneWidget, reason: '總預算已更新');

      // ── 5. 刪除分類預算：點項目→刪除 ──
      await tester.tap(find.text('餐飲食品（含子類）'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('budget-delete')), findsOneWidget,
          reason: '編輯模式可刪（收入目標無刪除鈕）');
      await tester.tap(find.byKey(const Key('budget-delete')));
      await tester.pumpAndSettle();
      expect(find.text('餐飲食品（含子類）'), findsNothing, reason: '分類預算已移除');
      expect(db.allBudgets().where((b) => b.categoryId != null), isEmpty,
          reason: '軟刪除後查無分類預算');
      expect(tester.takeException(), isNull);
    } finally {
      container.dispose();
      db.close();
    }
  });
}
