import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/scan/scan_state.dart';
import 'package:ledger_sync/application/sync/sync_fe_state.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/platform/scan/html5qrcode_scanner.dart';
import 'package:ledger_sync/presentation/screens/scan/import_page.dart';
import 'package:ledger_sync/presentation/screens/scan/review_page.dart';
import 'package:ledger_sync/presentation/screens/scan/web_camera_scan.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// F14 PWA 即時相機掃描（**T83——fake 掃描器＋fake 解析**；相機硬體/E2E
/// 另實機驗）：①JS 未載→資源缺失錯誤 ②相機不可用→回退檔案匯入
/// ③解碼命中→計數/草稿（TwEin 解析）④同張去重 ⑤完成掃描→確認清單。
void main() {
  /// 建 App＋覆寫（fake 掃描器）→ 回傳（container, fake）供斷言/驅動。
  Future<(ProviderContainer, _FakeScanner)> pumpPage(
    WidgetTester tester, {
    required _FakeScanner scanner,
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
      html5QrScannerProvider.overrideWithValue(scanner),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const WebCameraScanPage()),
    ));
    await tester.pump(); // initState → start（fake 立即完成）
    await tester.pump(const Duration(milliseconds: 700));
    return (container, scanner);
  }

  testWidgets('JS 未載 → 資源缺失錯誤＋「改用檔案匯入」回退', (tester) async {
    final (container, _) = await pumpPage(tester,
        scanner: _FakeScanner(jsLoaded: false, throwOnStart: false));
    expect(find.textContaining('掃描元件載入失敗'), findsOneWidget);
    expect(find.byKey(const Key('webcam-fallback-file')), findsOneWidget);
    await tester.tap(find.byKey(const Key('webcam-fallback-file')));
    await tester.pumpAndSettle();
    expect(find.byType(ImportPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(container.read(scanDraftsProvider), isEmpty);
  });

  testWidgets('相機不可用 → 顯示回退「改用檔案匯入」→ 開啟檔案匯入頁', (tester) async {
    final (container, _) = await pumpPage(tester,
        scanner: _FakeScanner(jsLoaded: true, throwOnStart: true));
    expect(find.text('相機無法使用'), findsOneWidget);
    expect(find.byKey(const Key('webcam-fallback-file')), findsOneWidget);
    await tester.tap(find.byKey(const Key('webcam-fallback-file')));
    await tester.pumpAndSettle();
    expect(find.byType(ImportPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(container.read(scanDraftsProvider), isEmpty);
  });

  testWidgets('解碼命中（TwEin 解析）→ 已掃 1 張（加入草稿）', (tester) async {
    final (_, fake) = await pumpPage(tester,
        scanner: _FakeScanner(jsLoaded: true, throwOnStart: false));
    expect(find.byKey(const Key('webcam-preview')), findsOneWidget);
    // 驅動 fake 解碼回呼：左碼＋右碼（fake.parseInvoice 回固定 TwEinInvoice）。
    fake.fireDecoded('LEFT');
    await tester.pump();
    fake.fireDecoded('**RIGHT');
    await tester.pump();
    expect(find.byKey(const Key('webcam-count')), findsOneWidget);
    expect(find.textContaining('已掃 1 張'), findsWidgets,
        reason: 'APP 欄＋列各一（連續掃描列）');
    expect(fake.parseCalls, greaterThanOrEqualTo(1),
        reason: '累積窗碼送 TwEin 解析');
    expect(tester.takeException(), isNull);
  });

  testWidgets('同張去重：同條碼內容不重複加入', (tester) async {
    final (container, fake) = await pumpPage(tester,
        scanner: _FakeScanner(jsLoaded: true, throwOnStart: false));
    fake.fireDecoded('LEFT');
    await tester.pump();
    fake.fireDecoded('**RIGHT');
    await tester.pump();
    fake.fireDecoded('LEFT'); // 同一張還在畫面中（重複回呼）
    await tester.pump();
    expect(container.read(scanDraftsProvider).length, 1,
        reason: 'QR 還在畫面中不應重複加入（_committedLeftCodes 擋）');
    expect(fake.parseCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('完成掃描 → 確認清單（ReviewPage）＋草稿清空', (tester) async {
    final (container, fake) = await pumpPage(tester,
        scanner: _FakeScanner(jsLoaded: true, throwOnStart: false));
    // 連續掃描預設關閉（PM 2026-11-22）——第一張即自動進確認清單；
    // 本測試驗「完成掃描」路徑 → 先開啟連續掃描（累積）。
    await tester.tap(find.byKey(const Key('scan-continuous-toggle')));
    await tester.pump();
    fake.fireDecoded('LEFT');
    await tester.pump();
    fake.fireDecoded('**RIGHT');
    await tester.pump();
    expect(container.read(scanDraftsProvider).length, 1);
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
}

/// fake 掃描器（Html5QrScanner 介面）：start 可丟例外；fireDecoded 由測試
/// 驅動回呼；parseInvoice 回固定 TwEinInvoice（記錄呼叫次數與輸入）。
class _FakeScanner implements Html5QrScanner {
  _FakeScanner({required this.jsLoaded, required this.throwOnStart});

  @override
  final bool jsLoaded;
  final bool throwOnStart;
  void Function(String)? _onDecoded;
  int parseCalls = 0;
  List<String>? lastParsedTexts;

  /// 測試驅動：模擬 html5-qrcode 解碼回呼。
  void fireDecoded(String text) => _onDecoded?.call(text);

  @override
  Future<void> start({
    required String elementId,
    required void Function(String text) onDecoded,
  }) async {
    if (throwOnStart) {
      throw StateError('相機無法使用（測試）');
    }
    _onDecoded = onDecoded;
  }

  @override
  Future<void> stop() async {}

  @override
  bool get torchSupported => false;

  @override
  bool get torchOn => false;

  @override
  Future<void> toggleTorch() async {}

  @override
  void registerReaderView(String viewType) {}

  @override
  Future<bool> checkReaderDivReady(String elementId) async => true; // fake: div ready

  @override
  TwEinInvoice? parseInvoice(List<String> texts) {
    parseCalls++;
    lastParsedTexts = texts;
    // 有左碼（非 ** 開頭）→ 回固定發票（TWD zero-decimal：total 245 元）。
    if (texts.any((t) => !t.startsWith('**'))) {
      return TwEinInvoice(
        invoiceNumber: 'AB11223344',
        date: DateTime(2026, 11, 24),
        totalAmountMinor: 245,
        sellerTaxId: null,
        randomCode: '1234',
        items: [
          const TwEinItem(name: '測試品項', quantity: 1, unitPrice: 245),
        ],
      );
    }
    return null; // 只有右碼——缺左碼。
  }

  @override
  Future<void> switchCamera() async {}

  @override
  String get facingLabel => 'environment';

  @override
  int get frameCount => 0;
}
