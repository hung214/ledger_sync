import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/budgets/budget_service.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/quick_entry/save_transaction_use_case.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/presentation/screens/overview/overview_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// T74（PM 2026-11-24）：總覽**預算摘要**對照雛型 01-dashboard——
/// 名稱＋「用量 / 額度（%）」＋進度條＋⚠ 門檻警示行（≥80% 顯示、
/// 超支換文案）；<80% 無警示行。
void main() {
  testWidgets('預算摘要：87.5% → 顯示「7,000 / 8,000（87.5%）」＋⚠ 門檻行',
      (tester) async {
    Clock.freeze(DateTime(2026, 11, 24, 12));
    final db = DbFixture.create();
    addTearDown(() {
      Clock.unfreeze();
      db.close();
    });
    await DbFixture.seedAccount(db, id: 'a-1', type: 'cash', name: '現金');
    await DbFixture.seedCategory(db,
        id: 'c-food', kind: 'expense', name: '餐飲');
    BudgetService(db, deviceId: 't').setCategoryBudget(
        categoryId: 'c-food', amountMinor: 800000, periodStartDay: 1); // 8,000
    SaveTransactionUseCase(db).execute(
      accountId: 'a-1',
      categoryId: 'c-food',
      amountMinor: 700000, // 7,000
      occurredAt: Clock.now(),
    );

    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-t')),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const OverviewPage()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('預算摘要'), findsOneWidget);
    expect(find.text('餐飲'), findsWidgets, reason: '分類名稱（摘要列＋最近交易皆可出現）');
    expect(find.text('7,000 / 8,000（87.5%）'), findsOneWidget,
        reason: '用量/額度（一位小數百分比）');
    expect(find.text('⚠ 已達 80% 警告門檻（N-1 已發送一次）'), findsOneWidget,
        reason: '≥80% 顯示門檻警示');
  });

  testWidgets('預算摘要：<80% 無警示行；超支顯示「⚠ 已超出預算」', (tester) async {
    Clock.freeze(DateTime(2026, 11, 24, 12));
    final db = DbFixture.create();
    addTearDown(() {
      Clock.unfreeze();
      db.close();
    });
    await DbFixture.seedAccount(db, id: 'a-1', type: 'cash', name: '現金');
    await DbFixture.seedCategory(db,
        id: 'c-a', kind: 'expense', name: '交通');
    await DbFixture.seedCategory(db,
        id: 'c-b', kind: 'expense', name: '娛樂');
    BudgetService(db, deviceId: 't')
      ..setCategoryBudget(
          categoryId: 'c-a', amountMinor: 100000, periodStartDay: 1) // 1,000
      ..setCategoryBudget(
          categoryId: 'c-b', amountMinor: 50000, periodStartDay: 1); // 500
    SaveTransactionUseCase(db)
      ..execute(
          accountId: 'a-1',
          categoryId: 'c-a',
          amountMinor: 30000, // 300 → 30%
          occurredAt: Clock.now())
      ..execute(
          accountId: 'a-1',
          categoryId: 'c-b',
          amountMinor: 60000, // 600 → 120%（超支）
          occurredAt: Clock.now());

    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-t')),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const OverviewPage()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('300 / 1,000（30%）'), findsOneWidget);
    expect(find.text('600 / 500（120%）'), findsOneWidget);
    expect(find.text('⚠ 已超出預算'), findsOneWidget, reason: '超支文案');
    // 30% 的交通預算無警示行（僅超支那一列有）。
    expect(find.text('⚠ 已達 80% 警告門檻（N-1 已發送一次）'), findsNothing);
  });
}
