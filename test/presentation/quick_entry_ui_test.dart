import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/first_run_bootstrap.dart';
import 'package:ledger_sync/application/quick_entry/quick_entry_memory.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/presentation/screens/quick_entry/quick_entry_controller.dart';

import '../helpers/in_memory_cloud_adapter.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/presentation/screens/quick_entry/quick_entry_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';

/// 快記頁 UI 快速護欄（PM 2026-10-22~24）：
/// ①v3 分類選擇**彈窗**（上常用／左主類別／右子類別；＋即建即選）
/// ②備註欄位寫入交易
/// ③「記住上次」：選子分類帶入上次金額＋帳戶＋商家
/// ④預算 mode：輸入完成 → 變成預算內容（非交易）
void main() {
  testWidgets('快記 v3：分類選擇彈窗（上常用／左主類別／右子類別）→ 選子分類', (tester) async {
    final db = DbFixture.create();
    await FirstRunBootstrap.seedIfNeeded(db);
    // 常用（MRU）來源：兩筆歷史交易（餐飲食品／交通運輸；後者最新）。
    await DbFixture.seedTx(db,
        id: 't1',
        kind: 'expense',
        amountMinor: 100,
        accountId: 'a-cash',
        category: 'c-food',
        occurredAt: DateTime.now().millisecondsSinceEpoch - 3600000);
    await DbFixture.seedTx(db,
        id: 't2',
        kind: 'expense',
        amountMinor: 100,
        accountId: 'a-cash',
        category: 'c-transport',
        occurredAt: DateTime.now().millisecondsSinceEpoch);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const QuickEntryPage()),
      ));
      await tester.pumpAndSettle();

      // 分類欄＝彈窗入口（不再平鋪分類格）。
      expect(find.byKey(const Key('quick-entry-category')), findsOneWidget);
      await tester.tap(find.byKey(const Key('quick-entry-category')));
      await tester.pumpAndSettle();

      expect(find.text('選擇分類'), findsOneWidget);
      // 開窗預設停在**目前所選分類**的主類別（快記有智慧預設 → selectedId 非 null）。
      expect(find.byKey(const Key('picker-main-交通運輸')), findsOneWidget);
      // ⭐ 常用類別（PM 2026-10-25）：左欄**最上方**；點它 → 右欄列出常用類別
      // **文字**（MRU：交通運輸最新）。原「上方分散 chips」已退役。
      expect(find.byKey(const Key('picker-freq')), findsOneWidget);
      expect(find.byKey(const Key('picker-recent-交通運輸')), findsNothing,
          reason: '舊「上方常用 chips」已退役（改 ⭐ 常用類別）');
      await tester.tap(find.byKey(const Key('picker-freq')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('picker-freq-交通運輸')), findsOneWidget);
      expect(find.byKey(const Key('picker-freq-餐飲食品')), findsOneWidget);
      // 左主類別／右子類別。
      expect(find.byKey(const Key('picker-main-餐飲食品')), findsOneWidget);
      await tester.tap(find.byKey(const Key('picker-main-餐飲食品')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('picker-sub-none')), findsOneWidget,
          reason: '「不分類」＝只記主類別');
      expect(find.byKey(const Key('picker-sub-早餐')), findsOneWidget,
          reason: '左欄選主類別 → 右欄列子分類');
      expect(find.byKey(const Key('picker-add-main')), findsOneWidget);
      expect(find.byKey(const Key('picker-add-sub')), findsOneWidget);

      // 選子分類 → 彈窗關閉、分類欄顯示所選。
      await tester.tap(find.byKey(const Key('picker-sub-早餐')));
      await tester.pumpAndSettle();
      expect(find.text('選擇分類'), findsNothing, reason: '選取後自動關閉');
      expect(
          find.descendant(
              of: find.byKey(const Key('quick-entry-category')),
              matching: find.text('🍜 早餐')),
          findsOneWidget,
          reason: '分類欄顯示主類別 emoji ＋ 子類別名（圖示跟隨主類別；PM 2026-10-24）');
      expect(container.read(quickEntryControllerProvider).category?.id,
          'c-food-s0');
      expect(tester.takeException(), isNull);
    } finally {
      container.dispose();
      db.close();
    }
  });

  testWidgets('快記：金額欄 autofocus 且為空（FR-Q1）', (tester) async {
    final db = DbFixture.create();
    await FirstRunBootstrap.seedIfNeeded(db);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const QuickEntryPage()),
      ));
      await tester.pumpAndSettle();
      // 金額欄自動聚焦（S1.1-5）——widget test 決定性（FE 因 macOS 視窗焦點不穩）。
      expect(find.byKey(const Key('quick-entry-amount')), findsOneWidget);
      final field = tester.widget<TextField>(
          find.byKey(const Key('quick-entry-amount')));
      expect(field.controller?.text ?? '', isEmpty, reason: '金額欄應為空');
      expect(field.autofocus, isTrue, reason: '金額欄標記 autofocus（FR-Q1）');
      // 真值焦點（widget test 決定性——FE 因 macOS 視窗焦點不穩，故落此處）。
      final editable = tester.widget<EditableText>(find.descendant(
          of: find.byKey(const Key('quick-entry-amount')),
          matching: find.byType(EditableText)));
      expect(editable.focusNode.hasFocus, isTrue,
          reason: '金額欄應已聚焦（FR-Q1；S1.1-5 數字鍵盤自動聚焦）');
      expect(tester.takeException(), isNull);
    } finally {
      container.dispose();
      db.close();
    }
  });

  testWidgets('快記 v3：備註欄位寫入交易（note）', (tester) async {
    final db = DbFixture.create();
    await FirstRunBootstrap.seedIfNeeded(db);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      // save → FR-Y11 afterSave 讀 syncCoordinatorProvider（須注入）。
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-t')),
    ]);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const QuickEntryPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('quick-entry-note')), findsOneWidget,
          reason: '備註欄（PM 2026-10-24）');
      for (final k in ['1', '5', '0']) {
        await tester.tap(find.byKey(Key('keypad-$k')));
        await tester.pump();
      }
      await tester.enterText(
          find.byKey(const Key('quick-entry-note')), '早餐');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('quick-entry-save')));
      await tester.pumpAndSettle();

      final txs = db.allTransactions();
      expect(txs.length, 1, reason: '已入庫一筆');
      expect(txs.first.note, '早餐', reason: '備註寫入交易（note）');
      expect(tester.takeException(), isNull);
    } finally {
      container.dispose();
      db.close();
    }
  });

  testWidgets('快記 v3：「記住上次」——選子分類帶入上次金額＋帳戶＋商家', (tester) async {
    final db = DbFixture.create();
    await FirstRunBootstrap.seedIfNeeded(db);
    // 預先寫入記憶（等同上次記過 c-food-s0＝早餐 150 元 / 現金 / 早餐店）。
    QuickEntryMemory(db).remember(
        categoryId: 'c-food-s0',
        amount: '150',
        accountId: 'a-cash',
        merchant: '早餐店');
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const QuickEntryPage()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('quick-entry-category')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picker-main-餐飲食品')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picker-sub-早餐')));
      await tester.pumpAndSettle();

      final st = container.read(quickEntryControllerProvider);
      expect(st.amount, '150', reason: '帶入上次金額');
      expect(st.merchant, '早餐店', reason: '帶入上次商家');
      expect(st.account?.id, 'a-cash', reason: '帶入上次帳戶');
      expect(find.text('150'), findsWidgets, reason: '金額欄顯示帶入值');
      expect(find.text('早餐店'), findsWidgets, reason: '商家欄顯示帶入值');
      expect(tester.takeException(), isNull);
    } finally {
      container.dispose();
      db.close();
    }
  });

}
