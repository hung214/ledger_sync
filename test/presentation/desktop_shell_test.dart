import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/first_run_bootstrap.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/presentation/screens/main_shell_page.dart';
import 'package:ledger_sync/presentation/screens/quick_entry/quick_entry_page.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';

import '../helpers/in_memory_cloud_adapter.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';

/// 桌面殼（08 雛型三欄）快速護欄：PC 與手機介面**明確區分**（PM 2026-10-23）——
/// 寬螢幕＝深色側欄＋工具列＋右側快記常駐面板；窄螢幕＝底部 NavigationBar。
void main() {
  testWidgets('桌面殼（寬 1600）：側欄＋工具列＋右側快記面板；面板儲存→交易入庫', (tester) async {
    final db = DbFixture.create();
    await FirstRunBootstrap.seedIfNeeded(db);
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      // save 後的 FR-Y11 afterSave 鉤子須注入（否則 UnimplementedError 中斷閉包）。
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
    ]);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light), home: const MainShellPage()),
      ));
      await tester.pumpAndSettle();

      // 三欄要件：側欄導航＋工具列搜尋/掃描/快記＋右側面板。
      expect(find.text('📒 LedgerSync'), findsOneWidget, reason: '側欄 logo（08）');
      expect(find.byKey(const Key('desktop-search')), findsOneWidget);
      expect(find.byKey(const Key('desktop-scan')), findsOneWidget);
      expect(find.byKey(const Key('fab-quick-entry')), findsOneWidget,
          reason: '工具列快記鈕（harness 相依 key）');
      expect(find.byKey(const Key('desktop-quick-amount')), findsOneWidget,
          reason: '右側快記常駐面板');
      expect(find.textContaining('雲端未設定'), findsOneWidget, reason: '側欄雲端狀態（footer 整段文字）');

      // PM 2026-10-25：桌面面板**無個別主類別選項**（三欄格已移除）。
      expect(find.byKey(const Key('cat-grid-餐飲食品')), findsNothing,
          reason: '面板不應有個別主類別選項（改由「分類」欄開彈窗）');
      // 面板：金額 120 → 鍵盤 OK 儲存 → 交易入庫（智慧預設帳戶）。
      await tester.enterText(find.byKey(const Key('desktop-quick-amount')), '120');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('quick-entry-save')));
      await tester.pump(); // 觸發 SnackBar 進場（pumpAndSettle 會快進 4s 自動關閉）
      await tester.pump(const Duration(milliseconds: 300));
      expect(db.allTransactions().length, 1, reason: '快記面板直接入庫');
      expect(db.allTransactions().first.amountMinor, 120);
      expect(find.textContaining('已入庫'), findsWidgets, reason: '儲存回饋');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      container.dispose();
      db.close();
    }
  });

  testWidgets('手機殼（窄 390）：底部 NavigationBar；桌面元件不出现', (tester) async {
    final db = DbFixture.create();
    await FirstRunBootstrap.seedIfNeeded(db);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      // save 後的 FR-Y11 afterSave 鉤子須注入（否則 UnimplementedError 中斷閉包）。
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
    ]);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light), home: const MainShellPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('nav-總覽')), findsOneWidget,
          reason: '底部導航（手機殼）');
      expect(find.byKey(const Key('desktop-search')), findsNothing,
          reason: '桌面工具列不應出現在手機殼');
      expect(find.byKey(const Key('desktop-quick-amount')), findsNothing,
          reason: '右側面板不應出現在手機殼');
      expect(tester.takeException(), isNull);
    } finally {
      container.dispose();
      db.close();
    }
  });

  testWidgets('桌面殼：工具列鈕＝切換右側面板（非整頁）；面板鍵盤可輸入（DBG-014）',
      (tester) async {
    final db = DbFixture.create();
    await FirstRunBootstrap.seedIfNeeded(db);
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
    ]);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const MainShellPage()),
      ));
      await tester.pumpAndSettle();

      // 面板預設常駐。
      expect(find.byKey(const Key('desktop-quick-amount')), findsOneWidget);
      // ①工具列鈕 → **收合**（不移除整頁；不推入 QuickEntryPage）。
      await tester.tap(find.byKey(const Key('fab-quick-entry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('desktop-quick-amount')), findsNothing,
          reason: 'PM 2026-10-26：桌面＝右側面板顯示/隱藏');
      expect(find.byType(QuickEntryPage), findsNothing,
          reason: '不應整頁切換到快記頁');
      // 再點 → 展開。
      await tester.tap(find.byKey(const Key('fab-quick-entry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('desktop-quick-amount')), findsOneWidget);

      // ②面板計算機：點 1／2／3 → 金額欄顯示 123（原僅改本地運算式＝無效果）。
      for (final k in ['keypad-1', 'keypad-2', 'keypad-3']) {
        await tester.tap(find.byKey(Key(k)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<TextField>(find.byKey(const Key('desktop-quick-amount')))
              .controller!
              .text,
          '123',
          reason: '鍵盤輸入須寫回金額欄與 controller（DBG-014）');

      // OK 儲存 → 入庫。
      await tester.tap(find.byKey(const Key('quick-entry-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(db.allTransactions().length, 1, reason: '鍵盤 OK 儲存');
      expect(db.allTransactions().first.amountMinor, 123);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      container.dispose();
      db.close();
    }
  });
}
