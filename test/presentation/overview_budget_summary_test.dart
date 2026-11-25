import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/budgets/budget_service.dart';
import 'package:ledger_sync/application/credit_card/repay_statement_use_case.dart';
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
        categoryId: 'c-food', amountMinor: 8000, periodStartDay: 1); // 8,000 元
    SaveTransactionUseCase(db).execute(
      accountId: 'a-1',
      categoryId: 'c-food',
      amountMinor: 7000, // 7,000 元
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
          categoryId: 'c-a', amountMinor: 1000, periodStartDay: 1) // 1,000 元
      ..setCategoryBudget(
          categoryId: 'c-b', amountMinor: 500, periodStartDay: 1); // 500 元
    SaveTransactionUseCase(db)
      ..execute(
          accountId: 'a-1',
          categoryId: 'c-a',
          amountMinor: 300, // 300 元 → 30%
          occurredAt: Clock.now())
      ..execute(
          accountId: 'a-1',
          categoryId: 'c-b',
          amountMinor: 600, // 600 元 → 120%（超支）
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

  testWidgets('T79 信用卡帳戶列＝負債語意：繳款後「應付」歸零（平帳）＋現金扣減',
      (tester) async {
    Clock.freeze(DateTime(2026, 11, 24, 12));
    final db = DbFixture.create();
    addTearDown(() {
      Clock.unfreeze();
      db.close();
    });
    await DbFixture.seedAccount(db,
        id: 'a-cash', type: 'cash', name: '現金', opening: 5000);
    await DbFixture.seedAccount(db, id: 'a-card', type: 'credit', name: '示例卡');
    // 刷卡 500（預扣 pending）＝待繳額度。
    await DbFixture.seedTx(db,
        id: 't-pend',
        kind: 'expense',
        amountMinor: 500,
        accountId: 'a-card',
        settlementStatus: 'pending',
        occurredAt: Clock.now().millisecondsSinceEpoch);

    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-t')),
    ]);
    addTearDown(container.dispose);

    Future<void> pump() async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light), home: const OverviewPage()),
      ));
      await tester.pumpAndSettle();
    }

    await pump();
    expect(find.text('應付 500'), findsOneWidget,
        reason: '信用卡列＝負債語意（T79——非 assetBalance 的 −500）');
    expect(find.text('餘額 5,000'), findsOneWidget, reason: '現金列');

    // 繳款（快記繳卡費同款路徑——executeForCard）。
    RepayStatementUseCase(db, container.read(notificationProvider))
        .executeForCard(
      cardAccountId: 'a-card',
      amountMinor: 500,
      fromAccountId: 'a-cash',
    );
    container.read(dataVersionProvider.notifier).bump(); // 模擬快記刷新
    await pump();

    expect(find.text('應付 0'), findsOneWidget, reason: '繳款後平帳（T79）');
    expect(find.text('餘額 4,500'), findsOneWidget, reason: '現金扣減 500');
  });

  testWidgets('T81 回歸：最近交易還款顯示「信用卡繳款」（Tx entity＝enum 比較）',
      (tester) async {
    Clock.freeze(DateTime(2026, 11, 24, 12));
    final db = DbFixture.create();
    addTearDown(() {
      Clock.unfreeze();
      db.close();
    });
    await DbFixture.seedAccount(db, id: 'a-cash', type: 'cash', name: '現金');
    await DbFixture.seedAccount(db, id: 'a-card', type: 'credit', name: '示例卡');
    // 還款交易（快記繳卡費/信用卡頁繳款之形態——categoryId=null）。
    await DbFixture.seedTx(db,
        id: 't-rep',
        kind: 'repayment',
        amountMinor: 500,
        accountId: 'a-cash',
        toAccountId: 'a-card',
        occurredAt: Clock.now().millisecondsSinceEpoch);

    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-t')),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light), home: const OverviewPage()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('信用卡繳款'), findsOneWidget,
        reason: 'T81——原碼 tx.kind == 字串（Tx entity 是 enum）恆 false → 顯示「交易」');
    expect(find.text('交易'), findsNothing, reason: '不再顯示含糊後備');
  });
}
