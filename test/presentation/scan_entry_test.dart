import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/first_run_bootstrap.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/scan/scan_state.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/presentation/screens/main_shell_page.dart';
import 'package:ledger_sync/presentation/screens/scan/import_page.dart';
import 'package:ledger_sync/presentation/screens/scan/scan_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// 掃描入口護欄（F03-FR-S6；PM 2026-10-29 回報「快捷沒反應／看不到 QRCODE」）：
/// - 桌面（無相機）→ **相簿/檔案匯入頁**（`ImportPage`）——PC 版設計如此。
/// - 有相機（手機）→ **QR 掃描頁**（`ScanPage`）。
/// 兩者皆由 ⌘⇧S／Ctrl+⇧S 開啟（全 App 僅 2 組快捷鍵之一）。
void main() {
  Future<void> pressCtrlShiftS(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<void> pump(WidgetTester tester, {required bool camera}) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await FirstRunBootstrap.seedIfNeeded(db);
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
      cameraAvailableProvider.overrideWith(() => _Cam(camera)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light), home: const MainShellPage()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('桌面（無相機）：⌘⇧S → 開啟**相簿/檔案匯入**頁', (tester) async {
    await pump(tester, camera: false);
    expect(find.byType(ImportPage), findsNothing, reason: '前置：尚未開啟');

    await pressCtrlShiftS(tester);

    expect(find.byType(ImportPage), findsOneWidget, reason: 'Ctrl+⇧S 應開啟匯入頁');
    expect(find.byType(ScanPage), findsNothing, reason: 'PC 無相機 → 不走 QR 掃描頁');
    expect(find.byKey(const Key('import-pick')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有相機（手機）：⌘⇧S → 開啟 **QR 掃描**頁', (tester) async {
    await pump(tester, camera: true);

    await pressCtrlShiftS(tester);

    expect(find.byType(ScanPage), findsOneWidget, reason: '有相機 → QR 掃描頁');
    expect(tester.takeException(), isNull);
  });
}

/// 相機可用性測試替身。
class _Cam extends CameraAvailableNotifier {
  _Cam(this._v);
  final bool _v;
  @override
  bool build() => _v;
}
