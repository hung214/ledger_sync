import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/first_run_bootstrap.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/presentation/screens/budget/budget_page.dart';
import 'package:ledger_sync/presentation/screens/ledger/tx_edit_sheet.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// 桌面（≥900）金額欄＝**實體鍵盤可輸入運算式**（PM 2026-11-27）：
/// 明細編輯交易＋預算表單；手機（<900）維持唯讀＋計算機輸入。
void main() {
  testWidgets('編輯交易（桌面 1080）：金額欄鍵盤輸入 50*3 → 儲存＝求值 150', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    final container = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A'),
        ),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1080, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showTxEditSheet(
                    context,
                    ref,
                    db.allTransactions().firstWhere((t) => t.id == 't-1'),
                    onChanged: () {},
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final amountField = tester.widget<TextField>(
      find.byKey(const Key('tx-edit-amount')),
    );
    expect(amountField.readOnly, isFalse, reason: '桌面 ≥900 → 可鍵盤輸入');

    await tester.enterText(find.byKey(const Key('tx-edit-amount')), '50*3');
    await tester.pumpAndSettle();
    // 鍵盤輸入含運算子 → ＝（keypad-equals）求值收合 50×3→150；
    // 變純數字後按鈕變 OK（quick-entry-save）＝存檔。
    await tester.tap(find.byKey(const Key('keypad-equals')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quick-entry-save')));
    await tester.pumpAndSettle();

    final tx = db.allTransactions().firstWhere((t) => t.id == 't-1');
    expect(tx.amountMinor, 150, reason: '運算式求值入庫（50*3＝150）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('編輯交易（手機 500）：金額欄維持唯讀（計算機輸入制不變）', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    final container = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A'),
        ),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showTxEditSheet(
                    context,
                    ref,
                    db.allTransactions().firstWhere((t) => t.id == 't-1'),
                    onChanged: () {},
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final amountField = tester.widget<TextField>(
      find.byKey(const Key('tx-edit-amount')),
    );
    expect(amountField.readOnly, isTrue, reason: '手機 <900 → 維持唯讀');
    expect(tester.takeException(), isNull);
  });

  testWidgets('預算表單（桌面 1080）：金額欄鍵盤輸入 30*2 → 儲存＝求值 60', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await FirstRunBootstrap.seedIfNeeded(db);
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1080, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const BudgetPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('budget-add')));
    await tester.pumpAndSettle();

    final amountField = tester.widget<TextField>(
      find.byKey(const Key('budget-amount')),
    );
    expect(amountField.readOnly, isFalse, reason: '桌面 ≥900 → 可鍵盤輸入');
    final dayField = tester.widget<TextField>(
      find.byKey(const Key('budget-start-day')),
    );
    expect(dayField.readOnly, isFalse, reason: '起始日桌面亦可鍵盤輸入');

    await tester.enterText(find.byKey(const Key('budget-amount')), '30*2');
    await tester.pumpAndSettle();
    // 起始日亦可鍵盤輸入（PM 2026-11-27：桌面兩欄都開放；僅數字）。
    await tester.enterText(find.byKey(const Key('budget-start-day')), '15');
    await tester.pumpAndSettle();
    // 計算機 OK＝儲存（金額 30*2＝60＋起始日 15）。
    await tester.tap(find.byKey(const Key('quick-entry-save')));
    await tester.pumpAndSettle();

    expect(find.text('/ 60'), findsOneWidget, reason: '總預算卡額度＝求值 60');
    final budget = db.allBudgets().first;
    expect(budget.amountMinor, 60);
    expect(budget.periodStartDay, 15, reason: '起始日＝鍵盤輸入 15');

    expect(find.text('/ 60'), findsOneWidget, reason: '總預算卡額度＝求值 60');
    expect(tester.takeException(), isNull);
  });
}
