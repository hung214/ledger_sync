import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/application/sync/sync_fe_state.dart';
import 'package:ledger_sync/presentation/merchant_picker_dialog.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// 商家選擇器（T8，PM 2026-11-22：商家「類別同款」**可選可增**）——
/// 直接輸入即新增；最近使用 chips（交易 DISTINCT merchant，免新表）。
void main() {
  ProviderContainer buildContainer(dynamic db) => ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        cloudAdapterProvider.overrideWithValue(InMemoryCloudAdapter()),
        syncCoordinatorProvider.overrideWithValue(
            SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
      ]);

  testWidgets('商家選擇器：最近使用 chips（依最近使用排序）＋點選回傳', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    // 兩家商家：蔡襄羹（最近）、全聯（較早）→ 排序＝蔡襄羹在前。
    await DbFixture.seedTx(db,
        id: 't-m1',
        kind: 'expense',
        amountMinor: 100,
        accountId: 'cash',
        merchant: '全聯',
        occurredAt: DateTime(2026, 11, 1).millisecondsSinceEpoch);
    await DbFixture.seedTx(db,
        id: 't-m2',
        kind: 'expense',
        amountMinor: 60,
        accountId: 'cash',
        merchant: '蔡襄羹',
        occurredAt: DateTime(2026, 11, 20).millisecondsSinceEpoch);

    expect(db.distinctMerchants(), ['蔡襄羹', '全聯'],
        reason: 'DISTINCT＋最近使用排序');

    String? picked;
    final container = buildContainer(db);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Consumer(builder: (context, ref, _) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async =>
                  picked = await showMerchantPicker(context, ref),
              child: const Text('open'),
            ),
          ),
        )),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('merchant-chip-蔡襄羹')), findsOneWidget);
    expect(find.byKey(const Key('merchant-chip-全聯')), findsOneWidget);

    await tester.tap(find.byKey(const Key('merchant-chip-全聯')));
    await tester.pumpAndSettle();
    expect(picked, '全聯', reason: '點 chip＝選定既有商家（可調整）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('商家選擇器：直接輸入新商家（＝新增）→ 確定回傳', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    final container = buildContainer(db);
    addTearDown(container.dispose);
    String? picked;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Consumer(builder: (context, ref, _) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async =>
                  picked = await showMerchantPicker(context, ref),
              child: const Text('open'),
            ),
          ),
        )),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('merchant-input')), '7-ELEVEN 敦南店');
    await tester.tap(find.byKey(const Key('merchant-pick-save')));
    await tester.pumpAndSettle();
    expect(picked, '7-ELEVEN 敦南店', reason: '直接輸入＝新增商家');
    expect(tester.takeException(), isNull);
  });
}
