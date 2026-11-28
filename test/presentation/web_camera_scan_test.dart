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
import '../helpers/invoice_qr_fixtures.dart';

/// F14 PWA 即時相機掃描（fake controller＋fake decoder——相機硬體/E2E 另實機驗）：
/// ①相機不可用→回退檔案匯入 ②解碼命中→計數/草稿 ③同張去重 ④完成掃描→確認清單
/// ⑤T91 順序掃描（左碼鎖定→時間窗獵右碼→合併/逾時入單）。
void main() {
  /// 建 App＋覆寫（fake 相機/解碼）→ 回傳 container 供斷言。
  Future<ProviderContainer> pumpPage(
    WidgetTester tester, {
    required CameraStreamController controller,
    required ({TransactionDraft? draft, List<String> texts})? Function(
      Uint8List,
    )
    decode,
    List<Override> extraOverrides = const [],
  }) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        cloudAdapterProvider.overrideWithValue(InMemoryCloudAdapter()),
        syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A'),
        ),
        webCameraControllerProvider.overrideWithValue(controller),
        webCameraDecodeProvider.overrideWithValue(decode),
        ...extraOverrides,
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const WebCameraScanPage(),
        ),
      ),
    );
    await tester.pump(); // initState → start（fake 立即完成）
    await tester.pump(const Duration(milliseconds: 50));
    return container;
  }

  testWidgets('相機不可用 → 顯示回退「改用檔案匯入」→ 開啟檔案匯入頁', (tester) async {
    await pumpPage(
      tester,
      controller: _FakeController(throwOnStart: true),
      decode: (_) => null,
    ); // 無命中
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
    final container = await pumpPage(
      tester,
      controller: _FakeController(),
      decode: (_) {
        calls++;
        return calls == 1
            ? (draft: draft, texts: const ['TEST'])
            : null; // 第一幀命中、之後沒有新 QR
      },
    );
    expect(find.byKey(const Key('webcam-preview')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1300)); // 解碼迴圈第一輪
    expect(find.byKey(const Key('webcam-count')), findsOneWidget);
    expect(
      find.textContaining('已掃 1 張'),
      findsWidgets,
      reason: 'APP 欄＋列各一（新增的連續掃描列）',
    );
    expect(container.read(scanDraftsProvider).length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同張去重：同條碼內容不重複加入', (tester) async {
    final draft = TransactionDraft.blank(DateTime(2026, 11, 17));
    final container = await pumpPage(
      tester,
      controller: _FakeController(),
      decode: (_) => (draft: draft, texts: const ['SAME']),
    ); // 每幀同一張
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump(const Duration(milliseconds: 1300));
    expect(
      container.read(scanDraftsProvider).length,
      1,
      reason: 'QR 還在畫面中不應重複加入',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('完成掃描 → 確認清單（ReviewPage）＋草稿清空', (tester) async {
    final draft = TransactionDraft.blank(DateTime(2026, 11, 17));
    final container = await pumpPage(
      tester,
      controller: _FakeController(),
      decode: (_) => (draft: draft, texts: const ['DONE']),
    );
    // 連續掃描預設關閉（PM 2026-11-22）——第一幀即自動進確認清單；
    // 本測試驗「完成掃描」路徑 → 先開啟連續掃描（累積）。
    await tester.tap(find.byKey(const Key('scan-continuous-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.tap(find.byKey(const Key('webcam-done')));
    await tester.pumpAndSettle();
    expect(find.byType(ReviewPage), findsOneWidget);
    await tester.pageBack(); // 完成確認返回 → 清空草稿、繼續掃
    // 單幀 pump：pop 完成 → reset 必已執行。**不用 pumpAndSettle**——
    // T91 返回後「立即恢復掃描」且 _seenCodes 已清 → 同碼仍在畫面中會被
    // 重新加入（正確行為）；慢機器（CI ubuntu）上重加搶在斷言前＝race
    //（2026-11-28 CI 紅根因；T91 為直接合併、此返回路徑首度跑 CI）。
    await tester.pump();
    expect(
      container.read(scanDraftsProvider),
      isEmpty,
      reason: '確認返回後清空草稿（下一輪繼續掃）',
    );
    expect(find.byKey(const Key('webcam-preview')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('T88 cover 映射：video 1280×720 → 顯示 640×480（放大置中、裁切區負座標）', () {
    // scale = max(640/1280, 480/720) = 2/3；dx = (640 − 853.33)/2 ≈ −106.67
    final r = mapVideoRectToDisplay(
      const Rect.fromLTWH(640, 360, 300, 150),
      const Size(1280, 720),
      const Size(640, 480),
    );
    expect(r.left, closeTo(426.67 - 106.67, 0.01)); // 640×⅔ − dx
    expect(r.top, closeTo(240, 0.01));
    expect(r.width, closeTo(200, 0.01));
    expect(r.height, closeTo(100, 0.01));
    // cover 左緣裁切區的框 → 負座標（Stack 裁切，允許）
    final r2 = mapVideoRectToDisplay(
      const Rect.fromLTWH(0, 0, 160, 90),
      const Size(1280, 720),
      const Size(640, 480),
    );
    expect(r2.left, closeTo(-106.67, 0.01));
    // 無畫面 → Rect.zero（不繪）
    expect(
      mapVideoRectToDisplay(
        const Rect.fromLTWH(0, 0, 10, 10),
        Size.zero,
        const Size(1, 1),
      ),
      Rect.zero,
    );
  });

  testWidgets('T88 偵測框：原生偵測回框 → CustomPaint 掛載', (tester) async {
    await pumpPage(
      tester,
      controller: _FakeController(
        nativeCodes: [
          const DetectedCode(
            text: 'LEFT',
            box: Rect.fromLTWH(100, 100, 200, 120),
          ),
          const DetectedCode(text: 'RIGHT'), // 無框（不繪）
        ],
        res: '1280x720',
      ),
      decode: (_) => null,
    ); // 不命中——停留掃描頁看框
    await tester.pump(const Duration(milliseconds: 1300)); // 解碼迴圈第一輪
    expect(find.byKey(const Key('code-boxes-paint')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ============ T91 順序掃描（先左後右＋時間窗＋ROI） ============

  /// 條件驅動 pump（每輪 110ms＝恰好跨過一個 100ms 掃描 tick——避免
  /// 「一次 pump 連發兩 tick」的時序脆弱；上限 12 輪防掛死）。
  Future<void> pumpUntil(WidgetTester tester, bool Function() cond) async {
    for (var i = 0; i < 12 && !cond(); i++) {
      await tester.pump(const Duration(milliseconds: 110));
    }
    expect(cond(), isTrue, reason: 'pumpUntil：條件未在 12 tick 內成立');
  }

  bool holdStarted() => find.textContaining('左碼已鎖定').evaluate().isNotEmpty;

  test('T91 顯示→video 反向映射（與 mapVideoRectToDisplay 互逆）', () {
    const video = Size(1920, 1080);
    const display = Size(1080, 1600);
    final box = const Rect.fromLTWH(900, 300, 400, 260);
    // 正向→反向還原。
    final shown = mapVideoRectToDisplay(box, video, display);
    final back = mapDisplayRectToVideo(shown, video, display);
    expect(back.left, closeTo(box.left, 0.01));
    expect(back.top, closeTo(box.top, 0.01));
    expect(back.width, closeTo(box.width, 0.01));
    expect(back.height, closeTo(box.height, 0.01));
    // 無畫面 → Rect.zero。
    expect(mapDisplayRectToVideo(box, Size.zero, display), Rect.zero);
  });

  testWidgets('T91 只掃到左碼 → 不立即入單、進入鎖定狀態（等右碼）', (tester) async {
    final container = await pumpPage(
      tester,
      controller: _FakeController(),
      decode: (_) => (draft: null, texts: [InvoiceQrFixtures.officialLeftQr77]),
    );
    await pumpUntil(tester, holdStarted);
    expect(
      container.read(scanDraftsProvider).length,
      0,
      reason: '左碼單獨出現＝先鎖定（舊行為會立即入單→明細漏接）',
    );
    expect(
      find.textContaining('對準右側明細碼'),
      findsOneWidget,
      reason: '時間窗開始——提示對準右側明細碼（含倒數）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('T91 時間窗內右碼到 → 合併入單（含右碼明細）', (tester) async {
    var texts = <String>[InvoiceQrFixtures.officialLeftQr77];
    final container = await pumpPage(
      tester,
      controller: _FakeController(),
      decode: (_) => (draft: null, texts: List.of(texts)),
    );
    await pumpUntil(tester, holdStarted);
    expect(container.read(scanDraftsProvider).length, 0);
    texts = [
      InvoiceQrFixtures.officialLeftQr77,
      InvoiceQrFixtures.officialRightQr,
    ];
    await pumpUntil(
      tester,
      () => container.read(scanDraftsProvider).length == 1,
    );
    final draft = container.read(scanDraftsProvider).first.draft;
    expect(
      draft.lineItems.map((e) => e.name),
      containsAll(['milk', 'coffee']),
      reason: '右碼明細補齊＝合併入單（舊行為左碼先入單會漏明細）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('T91 時間窗逾時（3s）→ 左碼先入單（無明細）、不重複入單', (tester) async {
    final container = await pumpPage(
      tester,
      controller: _FakeController(),
      decode: (_) => (draft: null, texts: [InvoiceQrFixtures.officialLeftQr77]),
      extraOverrides: [
        scanHoldWindowProvider.overrideWithValue(
          const Duration(milliseconds: 200),
        ),
      ],
    );
    await pumpUntil(tester, holdStarted);
    expect(container.read(scanDraftsProvider).length, 0);
    // 等 REAL 時間越過 hold 期限（DateTime.now() 為真實時鐘），下一 tick 逾時入單。
    // **testWidgets 本體＝FakeAsync**——裸 Future.delayed 等虛擬時鐘會永遠
    // 卡住（10 分鐘逾時）→ 必須 runAsync 跳回真實事件迴圈。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 320)),
    );
    await pumpUntil(
      tester,
      () => container.read(scanDraftsProvider).length == 1,
    );
    expect(
      container.read(scanDraftsProvider).first.draft.lineItems,
      isEmpty,
      reason: 'PM 決策：逾時＝左碼先入單（金額/日期/發票號到手，明細可補）',
    );
    await tester.pump(const Duration(milliseconds: 1300));
    expect(
      container.read(scanDraftsProvider).length,
      1,
      reason: '同一張左碼還在畫面中——不得重複入單',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('T91 一幀雙碼（後備解碼）→ 立即入單（快路徑回歸）', (tester) async {
    final container = await pumpPage(
      tester,
      controller: _FakeController(),
      decode: (_) => (
        draft: null,
        texts: [
          InvoiceQrFixtures.officialLeftQr77,
          InvoiceQrFixtures.officialRightQr,
        ],
      ),
    );
    await pumpUntil(
      tester,
      () => container.read(scanDraftsProvider).length == 1,
    );
    final draft = container.read(scanDraftsProvider).first.draft;
    expect(draft.lineItems.map((e) => e.name), containsAll(['milk', 'coffee']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('T91 一幀雙碼（原生偵測）→ 立即入單（快路徑回歸）', (tester) async {
    final container = await pumpPage(
      tester,
      controller: _FakeController(
        nativeCodes: [
          const DetectedCode(
            text: InvoiceQrFixtures.officialLeftQr77,
            box: Rect.fromLTWH(100, 500, 500, 300),
          ),
          const DetectedCode(
            text: InvoiceQrFixtures.officialRightQr,
            box: Rect.fromLTWH(1300, 500, 500, 300),
          ),
        ],
        res: '1920x1080',
      ),
      decode: (_) => null,
    );
    await pumpUntil(
      tester,
      () => container.read(scanDraftsProvider).length == 1,
    );
    final draft = container.read(scanDraftsProvider).first.draft;
    expect(draft.lineItems.map((e) => e.name), containsAll(['milk', 'coffee']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('T91 hold 階段走右側 ROI（captureAnalysisFrame 帶 region）', (
    tester,
  ) async {
    final controller = _FakeController(
      res: '1920x1080',
      analysisFrame: AnalysisFrame(
        rgba: Uint8List(8 * 8 * 4),
        width: 8,
        height: 8,
      ),
    );
    final container = await pumpPage(
      tester,
      controller: controller,
      decode: (_) => (draft: null, texts: [InvoiceQrFixtures.officialLeftQr77]),
      extraOverrides: [
        // ROI 子區解碼（fake——直接回右碼；驗證「只解 ROI」的接線）。
        webCameraDecodeRegionProvider.overrideWithValue(
          (af) => ['**milk:1:25'],
        ),
      ],
    );
    await pumpUntil(tester, holdStarted);
    expect(container.read(scanDraftsProvider).length, 0);
    expect(controller.lastCaptureRegion, isNull, reason: 'FULL 階段擷幀不帶 region');
    await pumpUntil(
      tester,
      () => container.read(scanDraftsProvider).length == 1,
    );
    expect(
      controller.lastCaptureRegion,
      isNotNull,
      reason: 'hold 階段擷幀帶右側 ROI（非全幅）',
    );
    expect(
      controller.lastCaptureRegion!.left,
      greaterThan(0),
      reason: 'ROI 在 video 右半',
    );
    expect(
      container.read(scanDraftsProvider).first.draft.lineItems.first.name,
      'milk',
      reason: 'ROI 解出的右碼與鎖定左碼合併',
    );
    expect(tester.takeException(), isNull);
  });
}

/// fake 相機控制器：start 可丟例外；captureFrame 回填位資料。
/// [nativeCodes] 非空＝模擬原生 BarcodeDetector（T88 偵測框）；
/// [analysisFrame] 非空＝模擬 RGBA ROI 擷幀（T91——hold 階段帶 region 時回傳）。
class _FakeController implements CameraStreamController {
  _FakeController({
    this.throwOnStart = false,
    this.nativeCodes = const [],
    this.res = '',
    this.analysisFrame,
  });

  final bool throwOnStart;
  final List<DetectedCode> nativeCodes;
  final String res;
  final AnalysisFrame? analysisFrame;

  /// 最近一次擷幀/偵測的 ROI（T91 斷言用——null＝全幅）。
  Rect? lastCaptureRegion;
  Rect? lastDetectRegion;

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
  Future<AnalysisFrame?> captureAnalysisFrame({Rect? region}) async {
    lastCaptureRegion = region;
    // 帶 region＝hold 階段 ROI 擷幀（T91）；全幅維持 null（JPEG 解碼路徑）。
    return region != null ? analysisFrame : null;
  }

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
  Future<List<DetectedCode>> detectNativeBarcodes({Rect? region}) async {
    lastDetectRegion = region;
    return nativeCodes;
  }

  @override
  bool get torchSupported => false;

  @override
  Future<void> toggleTorch() async {}

  @override
  bool get torchOn => false;

  @override
  void dispose() {}
}
