import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/scan/scan_state.dart';
import 'package:ledger_sync/domain/services/invoice_qr_parser.dart';
import 'package:ledger_sync/presentation/screens/scan/import_page.dart';
import 'package:ledger_sync/presentation/screens/scan/review_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';
import '../helpers/invoice_qr_fixtures.dart';

/// PC 掃描＝匯入圖片（PM 2026-10-29）：選檔 → 解析草稿 → **確認頁**。
/// 管線以 fake 注入（真檔對話框屬平台層；純 Dart 解碼路徑見
/// `test/platform/image_qr_scan_test.dart`）。
void main() {
  testWidgets('匯入圖片：選檔 → 確認頁顯示解析結果（商家／總額）', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    final draft = InvoiceQrParser.parse(
        InvoiceQrFixtures.leftQr77, InvoiceQrFixtures.rightQr)!;
    final item = ScannedItem(
        draft: draft, photoBytes: Uint8List.fromList(const [1, 2, 3]));

    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      importPipelineProvider.overrideWithValue(() async => item),
    ]);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light), home: const ImportPage()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('匯入圖片'), findsOneWidget, reason: '桌面匯入頁（原「相簿/檔案匯入」）');
    expect(find.byKey(const Key('import-pick')), findsOneWidget);
    expect(find.textContaining('選擇圖片'), findsWidgets);

    await tester.tap(find.byKey(const Key('import-pick')));
    await tester.pumpAndSettle();

    expect(find.byType(ReviewPage), findsOneWidget, reason: '選檔後進確認頁');
    expect(find.textContaining('測試超商'), findsWidgets, reason: 'QR 商家帶入');
    expect(tester.takeException(), isNull);
  });

  testWidgets('匯入圖片：使用者取消選檔 → 不進確認頁', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedStandardScenario(db);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      importPipelineProvider.overrideWithValue(() async => null), // 取消
    ]);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light), home: const ImportPage()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('import-pick')));
    await tester.pumpAndSettle();

    expect(find.byType(ReviewPage), findsNothing, reason: '取消＝不建立草稿');
    expect(find.byType(ImportPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
