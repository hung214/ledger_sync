import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/scan/scan_state.dart';
import 'package:ledger_sync/application/sync/sync_fe_state.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/domain/entities/transaction_draft.dart';
import 'package:ledger_sync/platform/scan/camera_stream.dart';
import 'package:ledger_sync/presentation/screens/scan/import_page.dart';
import 'package:ledger_sync/presentation/screens/scan/review_page.dart';
import 'package:ledger_sync/presentation/screens/scan/scan_box_mapper.dart';
import 'package:ledger_sync/presentation/screens/scan/web_camera_scan.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// F14 PWA 即時相機掃描（fake controller＋fake decoder——相機硬體/E2E 另實機驗）：
/// ①相機不可用→回退檔案匯入 ②解碼命中→計數/草稿 ③同張去重 ④完成掃描→確認清單。
void main() {
  /// 建 App＋覆寫（fake 相機/解碼）→ 回傳 container 供斷言。
  Future<ProviderContainer> pumpPage(
    WidgetTester tester, {
    required CameraStreamController controller,
    required ({TransactionDraft? draft, List<String> texts})? Function(
            Uint8List)
        decode,
  }) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      cloudAdapterProvider.overrideWithValue(InMemoryCloudAdapter()),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
      webCameraControllerProvider.overrideWithValue(controller),
      webCameraDecodeProvider.overrideWithValue(decode),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const WebCameraScanPage()),
    ));
    await tester.pump(); // initState → start（fake 立即完成）
    await tester.pump(const Duration(milliseconds: 50));
    return container;
  }

  testWidgets('相機不可用 → 顯示回退「改用檔案匯入」→ 開啟檔案匯入頁', (tester) async {
    await pumpPage(tester,
        controller: _FakeController(throwOnStart: true),
        decode: (_) => null); // 無命中
    expect(find.text('相機無法使用'), findsOneWidget);
    expect(find.byKey(const Key('webcam-fallback-file')), findsOneWidget);

    await tester.tap(find.byKey(const Key('webcam-fallback-file')));
    await tester.pumpAndSettle();
    expect(find.byType(ImportPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('預覽＋解碼命中 → 已掃 1 張（加入草稿）', (tester) async {
    final draft = TransactionDraft.blank(DateTime(2026, 11, 17));
    var calls = 0;
    final container = await pumpPage(tester,
        controller: _FakeController(),
        decode: (_) {
          calls++;
          return calls == 1
              ? (draft: draft, texts: const ['TEST'])
              : null; // 第一幀命中、之後沒有新 QR
        });
    expect(find.byKey(const Key('webcam-preview')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1300)); // 解碼迴圈第一輪
    expect(find.byKey(const Key('webcam-count')), findsOneWidget);
    expect(find.textContaining('已掃 1 張'), findsWidgets,
        reason: 'APP 欄＋列各一（新增的連續掃描列）');
    expect(container.read(scanDraftsProvider).length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同張去重：同條碼內容不重複加入', (tester) async {
    final draft = TransactionDraft.blank(DateTime(2026, 11, 17));
    final container = await pumpPage(tester,
        controller: _FakeController(),
        decode: (_) => (draft: draft, texts: const ['SAME'])); // 每幀同一張
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump(const Duration(milliseconds: 1300));
    expect(container.read(scanDraftsProvider).length, 1,
        reason: 'QR 還在畫面中不應重複加入');
    expect(tester.takeException(), isNull);
  });

  testWidgets('完成掃描 → 確認清單（ReviewPage）＋草稿清空', (tester) async {
    final draft = TransactionDraft.blank(DateTime(2026, 11, 17));
    final container = await pumpPage(tester,
        controller: _FakeController(),
        decode: (_) => (draft: draft, texts: const ['DONE']));
    // 連續掃描預設關閉（PM 2026-11-22）——第一幀即自動進確認清單；
    // 本測試驗「完成掃描」路徑 → 先開啟連續掃描（累積）。
    await tester.tap(find.byKey(const Key('scan-continuous-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.tap(find.byKey(const Key('webcam-done')));
    await tester.pumpAndSettle();
    expect(find.byType(ReviewPage), findsOneWidget);
    await tester.pageBack(); // 完成確認返回 → 清空草稿、繼續掃
    await tester.pumpAndSettle();
    expect(container.read(scanDraftsProvider), isEmpty,
        reason: '確認返回後清空草稿（下一輪繼續掃）');
    expect(find.byKey(const Key('webcam-preview')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('T88 cover 映射：video 1280×720 → 顯示 640×480（放大置中、裁切區負座標）', () {
    // scale = max(640/1280, 480/720) = 2/3；dx = (640 − 853.33)/2 ≈ −106.67
    final r = mapVideoRectToDisplay(const Rect.fromLTWH(640, 360, 300, 150),
        const Size(1280, 720), const Size(640, 480));
    expect(r.left, closeTo(426.67 - 106.67, 0.01)); // 640×⅔ − dx
    expect(r.top, closeTo(240, 0.01));
    expect(r.width, closeTo(200, 0.01));
    expect(r.height, closeTo(100, 0.01));
    // cover 左緣裁切區的框 → 負座標（Stack 裁切，允許）
    final r2 = mapVideoRectToDisplay(const Rect.fromLTWH(0, 0, 160, 90),
        const Size(1280, 720), const Size(640, 480));
    expect(r2.left, closeTo(-106.67, 0.01));
    // 無畫面 → Rect.zero（不繪）
    expect(
        mapVideoRectToDisplay(
            const Rect.fromLTWH(0, 0, 10, 10), Size.zero, const Size(1, 1)),
        Rect.zero);
  });

  testWidgets('T88 偵測框：原生偵測回框 → CustomPaint 掛載', (tester) async {
    await pumpPage(tester,
        controller: _FakeController(
          nativeCodes: [
            const DetectedCode(text: 'LEFT', box: Rect.fromLTWH(100, 100, 200, 120)),
            const DetectedCode(text: 'RIGHT'), // 無框（不繪）
          ],
          res: '1280x720',
        ),
        decode: (_) => null); // 不命中——停留掃描頁看框
    await tester.pump(const Duration(milliseconds: 1300)); // 解碼迴圈第一輪
    expect(find.byKey(const Key('code-boxes-paint')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// fake 相機控制器：start 可丟例外；captureFrame 回填位資料。
/// [nativeCodes] 非空＝模擬原生 BarcodeDetector（T88 偵測框）。
class _FakeController implements CameraStreamController {
  _FakeController({
    this.throwOnStart = false,
    this.nativeCodes = const [],
    this.res = '',
  });

  final bool throwOnStart;
  final List<DetectedCode> nativeCodes;
  final String res;

  @override
  bool get zoomSupported => false; // T82 zoom 介面——fake 不支援（靜默）。

  @override
  Future<void> setZoom(double normalized) async {}

  @override
  Future<Widget> start() async {
    if (throwOnStart) {
      throw const CameraUnavailableException('相機無法使用（測試）');
    }
    return const SizedBox(key: Key('fake-preview'));
  }

  @override
  Future<Uint8List?> captureFrame() async => Uint8List.fromList([1]);

  @override
  Future<AnalysisFrame?> captureAnalysisFrame() async => null;

  @override
  Future<void> resumePreview() async {}

  @override
  Future<Widget?> restartPreviewFresh() async => null;

  @override
  Future<void> switchCamera() async {}

  @override
  String get diagInfo => '';

  @override
  String get resolutionInfo => res;

  @override
  bool get hasNativeBarcodeDetector => nativeCodes.isNotEmpty;

  @override
  Future<List<DetectedCode>> detectNativeBarcodes() async => nativeCodes;

  @override
  bool get torchSupported => false;

  @override
  Future<void> toggleTorch() async {}

  @override
  bool get torchOn => false;

  @override
  void dispose() {}
}
