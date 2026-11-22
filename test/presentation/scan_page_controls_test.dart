import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/scan/scan_state.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/application/sync/sync_fe_state.dart';
import 'package:ledger_sync/domain/entities/transaction_draft.dart';
import 'package:ledger_sync/presentation/screens/scan/review_page.dart';
import 'package:ledger_sync/presentation/screens/scan/scan_page.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// 權限直接 granted 的 notifier（跳過權限閘，直接驗掃描中本體）。
class _GrantedPermission extends CameraPermissionNotifier {
  @override
  CameraPermissionState build() => CameraPermissionState.granted;
}

/// 掃描頁控制項（PM 2026-11-21）：
/// ①模式切換（電子發票 QR／紙本發票）＋紙本「手動開一筆」
/// ②連續掃描開關——關閉時掃到一張自動進確認清單；預設開＝連拍累積。
/// 相機以 mobile_scanner method-channel stub 隔離（畫面回退 _CameraError；
/// 辨識硬體行為屬 acceptance 實機走查）。
void main() {
  const scannerChannel =
      MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(scannerChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(scannerChannel, null);
  });

  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = DbFixture.create();
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [
      cameraPermissionProvider.overrideWith(_GrantedPermission.new),
      dbProvider.overrideWithValue(db),
      cloudAdapterProvider.overrideWithValue(InMemoryCloudAdapter()),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ScanPage()),
    ));
    await tester.pump(); // 權限 granted → 掃描中（相機 stub → errorBuilder）
    await tester.pump(const Duration(milliseconds: 100));
    return container;
  }

  testWidgets('模式切換：紙本發票 → 顯示「手動開一筆」→ 點按加入空白卡', (tester) async {
    final container = await pumpPage(tester);
    expect(container.read(scanModeProvider), ScanMode.eInvoice);
    expect(find.byKey(const Key('scan-manual-entry')), findsNothing);

    await tester.tap(find.text('紙本發票'));
    await tester.pump();
    expect(container.read(scanModeProvider), ScanMode.paper);
    expect(find.byKey(const Key('scan-manual-entry')), findsOneWidget);

    await tester.tap(find.byKey(const Key('scan-manual-entry')));
    await tester.pump();
    expect(find.textContaining('已掃 1 張'), findsOneWidget);
  });

  testWidgets('連續掃描預設關（PM 2026-11-22）：注入草稿 → 自動進確認清單',
      (tester) async {
    final container = await pumpPage(tester);
    expect(container.read(continuousScanProvider), isFalse);

    container.read(scanDraftsProvider.notifier).add(
        ScannedItem(draft: TransactionDraft.blank(DateTime(2026, 11, 21))));
    await tester.pumpAndSettle();
    expect(find.byType(ReviewPage), findsOneWidget);
  });

  testWidgets('連續掃描開啟：注入草稿不自動跳頁（累積待「完成掃描」）', (tester) async {
    final container = await pumpPage(tester);
    await tester.tap(find.byKey(const Key('scan-continuous-toggle')));
    await tester.pump();
    expect(container.read(continuousScanProvider), isTrue);

    container.read(scanDraftsProvider.notifier).add(
        ScannedItem(draft: TransactionDraft.blank(DateTime(2026, 11, 21))));
    await tester.pump();
    expect(find.byType(ReviewPage), findsNothing);
    expect(find.textContaining('已掃 1 張'), findsOneWidget);
  });

  testWidgets('補光開關：點按不拋例外（行動平台手電筒＝靜默失敗）', (tester) async {
    final container = await pumpPage(tester);
    final torchFinder = find.byKey(const Key('scan-torch-toggle'));
    if (torchFinder.evaluate().isNotEmpty) {
      await tester.tap(torchFinder);
      await tester.pump();
    }
    expect(find.byType(ScanPage), findsOneWidget);
  });
}
