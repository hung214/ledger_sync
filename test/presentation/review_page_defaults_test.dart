import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/scan/scan_defaults.dart';
import 'package:ledger_sync/application/scan/scan_state.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/application/sync/sync_fe_state.dart';
import 'package:ledger_sync/domain/entities/account.dart';
import 'package:ledger_sync/domain/entities/invoice_line_item.dart';
import 'package:ledger_sync/domain/entities/transaction_draft.dart';
import 'package:ledger_sync/presentation/screens/scan/review_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// 測試容器（存檔需 sync 注入——同 web_camera_scan_test harness）。
ProviderContainer _container(dynamic db) => ProviderContainer(
  overrides: [
    dbProvider.overrideWithValue(db),
    cloudAdapterProvider.overrideWithValue(InMemoryCloudAdapter()),
    syncCoordinatorProvider.overrideWithValue(
      SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A'),
    ),
  ],
);

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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: ReviewPage(items: [ScannedItem(draft: draft)]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('帳戶：現金（Sticky）'), findsOneWidget, reason: '預設帳戶＝第一個現金帳戶');
    expect(find.text('發票號 SR30393603'), findsOneWidget, reason: '發票號碼自動寫入備註欄');
    // PM 2026-11-26 聚焦滑入制：計算機改為金額欄聚焦才滑入，先聚焦金額欄再斷言。
    await tester.tap(find.byKey(const Key('review-total')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('amount-keypad')),
      findsOneWidget,
      reason: '聚焦金額欄 → 計算機滑入（PM 2026-11-26 聚焦滑入制）',
    );
    expect(find.text('第 1 張 / 共 1 張'), findsOneWidget, reason: '進度列');
    expect(find.text('測試超商'), findsOneWidget, reason: '商家欄帶入（快記同款輸入欄）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('帳戶/類別＝最後一次掃描優先；入帳記住＋多張 Sticky＋單張移除', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    db.setSetting(kScanLastAccountKey, 'bank'); // 上次掃描用了銀行
    db.setSetting(kScanLastCategoryKey, 'c-food'); // 上次掃描用了餐飲
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
    final item1 = ScannedItem(draft: draft(195));
    final item2 = ScannedItem(draft: draft(60));
    container.read(scanDraftsProvider.notifier).add(item1);
    container.read(scanDraftsProvider.notifier).add(item2);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: ReviewPage(items: [item1, item2]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('帳戶：銀行（Sticky）'),
      findsOneWidget,
      reason: '最後一次掃描的帳戶優先於第一個現金帳戶',
    );
    expect(
      find.textContaining('餐飲'),
      findsOneWidget,
      reason: '類別＝最後一次掃描入帳的類別（非一律「其他」）',
    );

    // 第 1 張：金額 195（預填）→ OK 入帳 → 自動跳第 2 張（Sticky 沿用）。
    // 聚焦滑入制：先聚焦金額欄讓計算機滑入，再 tap OK。
    await tester.tap(find.byKey(const Key('review-total')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quick-entry-save')));
    await tester.pumpAndSettle();
    expect(db.getSetting(kScanLastAccountKey), 'bank', reason: '入帳即記住＝下次掃描預設');
    expect(db.getSetting(kScanLastCategoryKey), 'c-food', reason: '類別同款記住');
    expect(
      container.read(scanDraftsProvider).length,
      1,
      reason: '存檔只移除**該張**（單張編輯不清其他待掃）',
    );
    expect(find.text('第 2 張 / 共 2 張'), findsOneWidget);
    expect(find.text('帳戶：銀行（Sticky）'), findsOneWidget, reason: '同回合 Sticky 沿用');
    expect(find.textContaining('餐飲'), findsOneWidget, reason: '類別 Sticky 沿用');

    // 第 2 張：改用現金 → 入帳 → 記住現金。
    await tester.tap(find.byKey(const Key('review-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('現金').last);
    await tester.pumpAndSettle();
    // 聚焦滑入制：先聚焦金額欄讓計算機滑入，再 tap OK。
    await tester.tap(find.byKey(const Key('review-total')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quick-entry-save')));
    await tester.pumpAndSettle();
    expect(
      db.getSetting(kScanLastAccountKey),
      'cash',
      reason: '最後入帳的帳戶＝下次掃描預設',
    );
    expect(
      container.read(scanDraftsProvider),
      isEmpty,
      reason: '全部存完＝暫存清空（逐張移除）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('時間預設＝當下時刻（PM 2026-11-23）：掃描日期配當下 HH:mm', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    final container = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        cloudAdapterProvider.overrideWithValue(InMemoryCloudAdapter()),
        syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A'),
        ),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 官方 QR 草稿：日期 2023-10-17、時間＝00:00（無時間資訊）。
    final draft = TransactionDraft(
      merchant: const DraftField.none(),
      totalMinor: const DraftField(21, 1.0),
      date: DraftField(DateTime(2023, 10, 17), 1.0),
      invoiceNo: 'SR30393603',
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: ReviewPage(items: [ScannedItem(draft: draft)]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final now = DateTime.now();
    // 日期 ◀▶ 快調（±1 天）——時間應保持當下時刻。
    await tester.tap(find.byKey(const Key('review-date-prev')));
    await tester.pump();
    // 聚焦滑入制：先聚焦金額欄讓計算機滑入，再 tap OK。
    await tester.tap(find.byKey(const Key('review-total')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quick-entry-save')));
    await tester.pumpAndSettle();

    final txs = db.allTransactions();
    expect(txs, isNotEmpty);
    final occurred = DateTime.fromMillisecondsSinceEpoch(txs.first.occurredAt);
    expect(
      occurred,
      DateTime(2023, 10, 16, now.hour, now.minute),
      reason: '◀ 快調一天（2023-10-17→16）＋時間＝當下時刻（非 00:00）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('日期＝掃到即用（無確認閘）：2023 舊日期直接入帳＋發票號入備註', (tester) async {
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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: ReviewPage(items: [ScannedItem(draft: draft)]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('請確認日期'),
      findsNothing,
      reason: 'PM 2026-11-22：不需要確認時間按鈕——掃到即用，手動調整',
    );
    expect(find.text('發票號 SR30393603'), findsOneWidget, reason: '發票號寫入備註欄');

    // 直接 OK 入帳（無閘）→ 交易 note＝發票號、日期＝掃描值。
    // 聚焦滑入制：先聚焦金額欄讓計算機滑入，再 tap OK。
    await tester.tap(find.byKey(const Key('review-total')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quick-entry-save')));
    await tester.pumpAndSettle();
    final txs = db.allTransactions();
    expect(txs, isNotEmpty);
    expect(txs.first.note, '發票號 SR30393603');
    expect(txs.first.amountMinor, 21);
    final occurred = DateTime.fromMillisecondsSinceEpoch(txs.first.occurredAt);
    final now = DateTime.now();
    expect(
      occurred,
      DateTime(2023, 10, 17, now.hour, now.minute),
      reason: '日期＝掃描值；時間＝當下時刻（PM 2026-11-23）',
    );
    expect(txs.first.source, 'scan');
    expect(tester.takeException(), isNull);
  });

  testWidgets('確認清單備註右下「儲存」（PM 2026-11-27，僅手機）：點即存檔＋暫存移除＋返回', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    final container = _container(db);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(500, 1200); // 手機寬幅（<900 斷點）
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final draft = TransactionDraft(
      merchant: const DraftField('測試超商', 1.0),
      totalMinor: const DraftField(195, 1.0),
      date: DraftField(DateTime(2026, 10, 18), 1.0),
      invoiceNo: 'SR30393603',
    );
    final item = ScannedItem(draft: draft);
    container.read(scanDraftsProvider.notifier).add(item);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: ReviewPage(items: [item]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 金額由草稿預填 195 → 儲存啟用（與鍵盤 OK 同判定）。
    final btn = tester.widget<FilledButton>(
      find.byKey(const Key('review-save-btn')),
    );
    expect(btn.onPressed, isNotNull, reason: '金額 195 → 可存');

    // 點備註區「儲存」＝同鍵盤 OK 的存檔（單張→存完返回）。
    await tester.tap(find.byKey(const Key('review-save-btn')));
    await tester.pumpAndSettle();

    final txs = db.allTransactions();
    final saved = txs.where((t) => t.source == 'scan').toList();
    expect(saved.length, 1, reason: '已入庫一筆（seedStandardScenario 另有預載）');
    expect(saved.first.amountMinor, 195);
    expect(saved.first.note, '發票號 SR30393603', reason: '備註（含發票號）寫入');
    expect(container.read(scanDraftsProvider), isEmpty, reason: '存檔即從暫存移除該張');
    expect(find.byType(ReviewPage), findsNothing, reason: '全數完成 → 返回（S3.7）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('確認清單備註右下「儲存」＝僅手機版（≥900 桌面寬幅不渲染；PM 2026-11-27）', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    final container = _container(db);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1080, 1200); // 桌面寬幅（≥900 斷點）
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final draft = TransactionDraft(
      merchant: const DraftField('測試超商', 1.0),
      totalMinor: const DraftField(195, 1.0),
      date: DraftField(DateTime(2026, 10, 18), 1.0),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: ReviewPage(items: [ScannedItem(draft: draft)]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('review-save-btn')),
      findsNothing,
      reason: '桌面版不加備註區儲存鈕（與快記同慣例）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('T92b 備註＝發票號＋內容明細（一行一產品含數量金額——PM 2026-11-28）', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    final container = _container(db);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const lineItems = [
      InvoiceLineItem(name: 'milk', quantity: 2, unitPrice: 50, amount: 100),
      InvoiceLineItem(name: '麵包', quantity: 1, unitPrice: 60, amount: 60),
    ];
    final draft = TransactionDraft(
      merchant: const DraftField('測試超商', 1.0),
      totalMinor: const DraftField(160, 1.0),
      date: DraftField(DateTime(2026, 11, 18), 1.0),
      invoiceNo: 'SR30393603',
      lineItems: lineItems,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: ReviewPage(items: [ScannedItem(draft: draft)]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('review-note')))
          .controller!
          .text,
      '發票號 SR30393603\nmilk×2 100\n麵包×1 60',
      reason: '備註＝發票號＋明細（一行一產品：名稱×數量 金額）',
    );

    // 多行輸入 → 存檔完整（\n 保留；PM 2026-11-28）。
    await tester.enterText(
      find.byKey(const Key('review-note')),
      '發票號 SR30393603\nmilk×2 100\n麵包×1 60\n自加備註',
    );
    await tester.tap(find.byKey(const Key('review-save-btn')));
    await tester.pumpAndSettle();

    final txs = db.allTransactions().where((t) => t.source == 'scan').toList();
    expect(txs.length, 1, reason: '已入庫一筆');
    expect(
      txs.first.note,
      '發票號 SR30393603\nmilk×2 100\n麵包×1 60\n自加備註',
      reason: '多行備註存檔完整（\\n 保留）',
    );
    expect(tester.takeException(), isNull);
  });
}
