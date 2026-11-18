import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/lock/app_lock_controller.dart';
import 'package:ledger_sync/application/lock/pin_hash.dart';
import 'package:ledger_sync/application/lock/lock_fe_state.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/application/sync/sync_fe_state.dart';
import 'package:ledger_sync/presentation/screens/credit_card/credit_card_page.dart';
import 'package:ledger_sync/presentation/screens/settings/settings_hub_page.dart';
import 'package:ledger_sync/presentation/screens/settings/settings_sync_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// F16 UI 對照走查修正（6 缺口——DEMO 有、正式頁沒接）：
/// 同步模式三選一／附件 Wi-Fi／安全區塊（App 鎖+門檻+隱私遮蔽）／
/// 信用卡帳單歷史＋未來已承諾＋卡號。
void main() {
  testWidgets('U4/U5：同步模式三選一＋附件 Wi-Fi 開關（寫入 settings）', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      cloudAdapterProvider.overrideWithValue(InMemoryCloudAdapter()),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const SettingsSyncPage()),
    ));
    await tester.pumpAndSettle();

    // 預設＝節能批次；切「每筆自動」→ settings 更新
    await tester.ensureVisible(find.byKey(const Key('sync-mode-per')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sync-mode-per')));
    await tester.pump();
    expect(db.getSetting('sync.mode'), 'per-transaction');
    // 切 Wi-Fi 開關 → settings 更新
    await tester.ensureVisible(find.byKey(const Key('sync-attachments-wifi')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sync-attachments-wifi')));
    await tester.pump();
    expect(db.getSetting('backup.attachments_wifi_only'), 'true');
  });

  testWidgets('U6：安全區塊——隱私遮蔽開關＋門檻變更＋PIN 設定', (tester) async {
    PinHasher.kTestMode = true; // widget 假時鐘無法驅動 Argon2id 分段 Timer
    addTearDown(() => PinHasher.kTestMode = false);
    final db = DbFixture.create();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      appLockControllerProvider.overrideWithValue(
          AppLockController(db, thresholdSec: 30)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const SettingsHubPage()),
    ));
    await tester.pumpAndSettle();

    // 隱私遮蔽：開 → provider 變 true
    await tester.ensureVisible(find.byKey(const Key('security-privacy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('security-privacy')));
    await tester.pump();
    expect(container.read(privacyMaskedProvider), isTrue);

    // 門檻：30 → 60
    await tester.tap(find.byKey(const Key('security-threshold')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('60 秒').last);
    await tester.pump();
    expect(db.getSetting('lock.threshold_sec'), '60');

    // 設定 PIN：開對話框→輸入→儲存→hasPin
    await tester.tap(find.byKey(const Key('security-applock-set')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('security-pin-field')), '1234');
    await tester.tap(find.byKey(const Key('security-pin-save')));
    // Argon2id 內部分段以 Timer 完成——pumpAndSettle 可推進（前提：provider 已 override）。
    await tester.pumpAndSettle();
    expect(db.getSetting('lock.pin_hash'), startsWith('v2.argon2id\$'));
  });

  testWidgets('U1/U2/U3：信用卡頁——卡號＋未來已承諾＋帳單歷史', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    db.select(
        "INSERT INTO accounts (id,type,name,currency,opening_amount_minor,"
        "archived,created_at,updated_at,hlc) VALUES ('a-card','credit','範例卡','TWD',0,0,1,1,'0.t')");
    db.select(
        "INSERT INTO credit_card_details (account_id,last4,statement_day,"
        "due_offset_days,effective_from) VALUES ('a-card','1234',6,20,1)");
    // 本期（最新）＋歷史（部分繳）
    db.select(
        "INSERT INTO statements (id,account_id,period_start,period_end,statement_date,"
        "due_date,total_minor,paid_minor,status,overdue_notified,created_at,updated_at,hlc) "
        "VALUES ('s-2','a-card',1760000000000,1762000000000,1763000000000,"
        "1764500000000,800000,0,'unpaid',0,1,1,'0.t')");
    db.select(
        "INSERT INTO statements (id,account_id,period_start,period_end,statement_date,"
        "due_date,total_minor,paid_minor,status,overdue_notified,created_at,updated_at,hlc) "
        "VALUES ('s-1','a-card',1750000000000,1752000000000,1753000000000,"
        "1796000000000,500000,200000,'partial',0,1,1,'0.t')");
    // 未來分期扣款 2 筆
    db.select(
        "INSERT INTO transactions (id,kind,amount_minor,currency,account_id,"
        "occurred_at,source,settlement_status,created_at,updated_at,hlc,installment_seq) "
        "VALUES ('i-1','expense',500000,'TWD','a-card',1860000000000,'manual','none',1,1,'0.t',1)");
    db.select(
        "INSERT INTO transactions (id,kind,amount_minor,currency,account_id,"
        "occurred_at,source,settlement_status,created_at,updated_at,hlc,installment_seq) "
        "VALUES ('i-2','expense',500000,'TWD','a-card',1861000000000,'manual','none',1,1,'0.t',2)");

    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      cloudAdapterProvider.overrideWithValue(InMemoryCloudAdapter()),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const CreditCardPage(cardAccountId: 'a-card')),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('•••• •••• •••• 1234'), findsOneWidget,
        reason: 'U3 卡號');
    expect(find.text('未來已承諾（分期）'), findsOneWidget, reason: 'U2');
    expect(find.textContaining('1,000,000'), findsOneWidget,
        reason: 'U2 未來兩期合計 500,000×2');
    expect(find.text('帳單歷史'), findsOneWidget, reason: 'U1');
    expect(find.textContaining('部分繳'), findsOneWidget);
  });
}
