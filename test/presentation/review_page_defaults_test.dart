import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/scan/scan_defaults.dart';
import 'package:ledger_sync/application/scan/scan_state.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/application/sync/sync_fe_state.dart';
import 'package:ledger_sync/domain/entities/account.dart';
import 'package:ledger_sync/domain/entities/transaction_draft.dart';
import 'package:ledger_sync/presentation/screens/scan/review_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// 測試容器（存檔需 sync 注入——同 web_camera_scan_test harness）。
ProviderContainer _container(dynamic db) => ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      cloudAdapterProvider.overrideWithValue(InMemoryCloudAdapter()),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
    ]);

/// 確認清單＝**快記同款**（PM 2026-11-22）＋**掃描預設帳戶**（PM 2026-11-22）：
/// 帳戶預設＝最後一次掃描入帳的帳戶 → 第一個現金帳戶；入帳即記住（跨回合）。
/// 日期＝掃到即用（**無確認閘**——PM 2026-11-22 移除「已確認」按鈕，手動調整）；
/// 發票號碼自動寫入**備註欄**（PM 2026-11-22）。
void main() {
  group('resolveScanDefaultAccount（純函式）', () {
    final accounts = [
      const Account(id: 'bank', type: AccountType.bank, name: '銀行'),
      const Account(id: 'cash', type: AccountType.cash, name: '現金'),
      const Account(id: 'ewallet', type: AccountType.ewallet, name: '票證卡'),
    ];

    test('最後一次掃描帳戶存在 → 優先', () {
      expect(resolveScanDefaultAccount(accounts, 'ewallet'), 'ewallet');
    });

    test('最後一次掃描帳戶已刪除 → 第一個現金帳戶', () {
      expect(resolveScanDefaultAccount(accounts, 'gone'), 'cash');
    });

    test('無紀錄 → 第一個現金帳戶', () {
      expect(resolveScanDefaultAccount(accounts, null), 'cash');
    });

    test('無現金帳戶 → 第一個帳戶；無帳戶 → null', () {
      final noCash = [
        const Account(id: 'bank', type: AccountType.bank, name: '銀行'),
      ];
      expect(resolveScanDefaultAccount(noCash, null), 'bank');
      expect(resolveScanDefaultAccount(const [], null), isNull);
    });
  });

  testWidgets('確認清單：帳戶預設＝第一個現金帳戶（快記同款 UI）', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    final container = _container(db);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final draft = TransactionDraft(
      merchant: const DraftField('測試超商', 1.0),
      totalMinor: const DraftField(195, 1.0),
      date: DraftField(DateTime(2026, 10, 18), 1.0),
      invoiceNo: 'SR30393603',
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: ReviewPage(items: [ScannedItem(draft: draft)]),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('帳戶：現金（Sticky）'), findsOneWidget,
        reason: '預設帳戶＝第一個現金帳戶');
    expect(find.text('發票號 SR30393603'), findsOneWidget,
        reason: '發票號碼自動寫入備註欄');
    expect(find.byKey(const Key('amount-keypad')), findsOneWidget,
        reason: '快記同款：常駐計算機');
    expect(find.text('第 1 張 / 共 1 張'), findsOneWidget,
        reason: '進度列');
    expect(find.text('測試超商'), findsOneWidget,
        reason: '商家欄帶入（快記同款輸入欄）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('最後一次掃描的帳戶優先；入帳後記住（下次預設）＋多張 Sticky', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    db.setSetting(kScanLastAccountKey, 'bank'); // 上次掃描用了銀行
    final container = _container(db);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    TransactionDraft draft(int total) => TransactionDraft(
          merchant: const DraftField('測試超商', 1.0),
          totalMinor: DraftField(total, 1.0),
          date: DraftField(DateTime(2026, 10, 18), 1.0),
        );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: ReviewPage(items: [
          ScannedItem(draft: draft(195)),
          ScannedItem(draft: draft(60)),
        ]),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('帳戶：銀行（Sticky）'), findsOneWidget,
        reason: '最後一次掃描的帳戶優先於第一個現金帳戶');

    // 第 1 張：金額 195（預填）→ OK 入帳 → 自動跳第 2 張（帳戶 Sticky 沿用）。
    await tester.tap(find.byKey(const Key('quick-entry-save')));
    await tester.pumpAndSettle();
    expect(db.getSetting(kScanLastAccountKey), 'bank',
        reason: '入帳即記住＝下次掃描預設');
    expect(find.text('第 2 張 / 共 2 張'), findsOneWidget);
    expect(find.text('帳戶：銀行（Sticky）'), findsOneWidget,
        reason: '同回合 Sticky 沿用');

    // 第 2 張：改用現金 → 入帳 → 記住現金。
    await tester.tap(find.byKey(const Key('review-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('現金').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quick-entry-save')));
    await tester.pumpAndSettle();
    expect(db.getSetting(kScanLastAccountKey), 'cash',
        reason: '最後入帳的帳戶＝下次掃描預設');
    expect(tester.takeException(), isNull);
  });

  testWidgets('日期＝掃到即用（無確認閘）：2023 舊日期直接入帳＋發票號入備註',
      (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    final container = _container(db);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 民國 112 年 ibon 收據（官方 QR 帶入 2023-10-17＋發票號）。
    final draft = TransactionDraft(
      merchant: const DraftField.none(),
      totalMinor: const DraftField(21, 1.0),
      date: DraftField(DateTime(2023, 10, 17), 1.0),
      invoiceNo: 'SR30393603',
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: ReviewPage(items: [ScannedItem(draft: draft)]),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('請確認日期'), findsNothing,
        reason: 'PM 2026-11-22：不需要確認時間按鈕——掃到即用，手動調整');
    expect(find.text('發票號 SR30393603'), findsOneWidget,
        reason: '發票號寫入備註欄');

    // 直接 OK 入帳（無閘）→ 交易 note＝發票號、日期＝掃描值。
    await tester.tap(find.byKey(const Key('quick-entry-save')));
    await tester.pumpAndSettle();
    final txs = db.allTransactions();
    expect(txs, isNotEmpty);
    expect(txs.first.note, '發票號 SR30393603');
    expect(txs.first.amountMinor, 21);
    expect(DateTime.fromMillisecondsSinceEpoch(txs.first.occurredAt),
        DateTime(2023, 10, 17));
    expect(txs.first.source, 'scan');
    expect(tester.takeException(), isNull);
  });
}
