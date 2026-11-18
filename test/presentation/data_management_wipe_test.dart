import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/lock/app_lock_controller.dart';
import 'package:ledger_sync/application/lock/lock_fe_state.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/presentation/screens/settings/data_management_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';

/// 清空資料三重防護（F09）——**未設定 PIN 跳過 PIN 步驟**（PM 2026-10-23
/// 修復：verifyPin 對 null hash 恆 false，沒設過 PIN 的使用者會被鎖死）。
void main() {
  testWidgets('清空資料（未設定 PIN）：警告 → 直接進入確認文字（跳過 PIN）', (tester) async {
    final db = DbFixture.create();
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      // 無 PIN 裝置：建構子不給 pin（不寫 pin_hash）。
      appLockControllerProvider
          .overrideWithValue(AppLockController(db, thresholdSec: 30)),
    ]);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const DataManagementPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('wipe-start')), findsOneWidget);
      await tester.tap(find.byKey(const Key('wipe-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wipe-scope-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wipe-warning-continue')));
      await tester.pumpAndSettle();

      // 未設定 PIN → 直接落在「確認文字」步驟（不出現 PIN 輸入）。
      expect(find.byKey(const Key('wipe-confirm-input')), findsOneWidget,
          reason: '無 PIN → 跳過 PIN 步驟（2026-10-23 修復）');
      expect(find.byKey(const Key('wipe-pin-input')), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      container.dispose();
      db.close();
    }
  });

  testWidgets('清空資料（已設定 PIN）：仍要求 PIN（既有三重防護不變）', (tester) async {
    final db = DbFixture.create();
    // Argon2id 內部以 Future.delayed 分段——widget 測試須 runAsync（真實時間）。
    final lock = (await tester.runAsync(() =>
        AppLockController.create(db, pin: '1234', thresholdSec: 30)))!;
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      appLockControllerProvider.overrideWithValue(lock),
    ]);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const DataManagementPage()),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wipe-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wipe-scope-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wipe-warning-continue')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('wipe-pin-input')), findsOneWidget,
          reason: '已設定 PIN → 維持 PIN 關卡');
      expect(find.byKey(const Key('wipe-confirm-input')), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      container.dispose();
      db.close();
    }
  });
}
