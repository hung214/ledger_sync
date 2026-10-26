import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/presentation/screens/ledger/ledger_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';

/// 明細交易列顯示。
/// - **標題＝分類（含子類別名）**（PM 2026-10-26：原為商家，常態顯示「—」）
/// - 左側＝分類圖示圓（**子類別取主類別圖示**）
/// - 副標＝時間 · 帳戶[ · 商家][ · 備註][ · 標籤]
void main() {
  testWidgets('明細列：商家／分類（主類別圖示）／帳戶／備註 齊備', (tester) async {
    final db = DbFixture.create();
    const occurredAt = 1760736000000; // 2026/10/18 08:00
    await DbFixture.seedAccount(
        db, id: 'a-1', type: 'cash', name: '現金', opening: 0);
    await DbFixture.seedTx(db,
        id: 't-1',
        kind: 'expense',
        amountMinor: 120,
        accountId: 'a-1',
        category: 'c-food-s0', // 子類別（無自身圖示）
        merchant: '晨光早餐店',
        occurredAt: occurredAt);
    db.setTransactionNote('t-1', '早餐');
    final tx = db.allTransactions().firstWhere((t) => t.id == 't-1');

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: TxTile(
          tx: tx,
          accountName: '現金',
          categoryName: '早餐',
          categoryId: 'c-food-s0',
          categoryIcon: '🍜', // 主類別 emoji（子類別→取主類別）
          note: '早餐',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('早餐'), findsWidgets,
        reason: '標題＝分類（含子類別名；PM 2026-10-26）');
    expect(find.text('🍜'), findsOneWidget,
        reason: '分類圖示圓＝主類別 emoji（子類別無自身圖示）');
    final expected =
        '${DateFormat('yyyy/MM/dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(occurredAt))}'
        ' · 現金 · 晨光早餐店 · 早餐';
    expect(find.text(expected), findsOneWidget,
        reason: '副標＝時間 · 帳戶 · 商家 · 備註（商家自標題移入）');
    expect(find.text('-120'), findsOneWidget, reason: '支出顯示負號');
    expect(tester.takeException(), isNull);
    db.close();
  });

  testWidgets('明細列：無商家→仍以分類名為標題（不再出現「—」）', (tester) async {
    final db = DbFixture.create();
    await DbFixture.seedAccount(
        db, id: 'a-1', type: 'cash', name: '現金', opening: 0);
    await DbFixture.seedTx(db,
        id: 't-2',
        kind: 'expense',
        amountMinor: 35,
        accountId: 'a-1',
        category: 'c-transport',
        occurredAt: 1760736000000);
    final tx = db.allTransactions().firstWhere((t) => t.id == 't-2');

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: TxTile(
          tx: tx,
          accountName: '現金',
          categoryName: '交通運輸',
          categoryId: 'c-transport',
          categoryIcon: '🚇',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('—'), findsNothing,
        reason: 'PM 2026-10-26：標題改為分類——無商家時不再顯示「—」');
    expect(find.text('交通運輸'), findsWidgets,
        reason: '標題＝分類名（無商家仍可讀）');
    expect(find.text('🚇'), findsOneWidget);
    expect(find.textContaining('現金'), findsWidgets, reason: '副標含帳戶');
    expect(tester.takeException(), isNull);
    db.close();
  });

  testWidgets('明細頁（手機）：分日群組（今天／昨天）＋每日小計＋列內容與顏色', (tester) async {
    Clock.freeze(DateTime(2026, 10, 18, 12));
    addTearDown(Clock.unfreeze);
    final db = DbFixture.create();
    await DbFixture.seedAccount(
        db, id: 'a-1', type: 'cash', name: '現金', opening: 0);
    await DbFixture.seedCategory(db,
        id: 'c-food', kind: 'expense', name: '餐飲食品');
    await DbFixture.seedCategory(db,
        id: 'c-food-s0', kind: 'expense', name: '早餐', parentId: 'c-food');
    db.execute("UPDATE categories SET icon='🍜' WHERE id='c-food'");
    await DbFixture.seedTx(db,
        id: 't1',
        kind: 'expense',
        amountMinor: 195,
        accountId: 'a-1',
        category: 'c-food',
        merchant: '陽光超商',
        occurredAt: DateTime(2026, 10, 18, 9, 12).millisecondsSinceEpoch);
    await DbFixture.seedTx(db,
        id: 't2',
        kind: 'expense',
        amountMinor: 120,
        accountId: 'a-1',
        category: 'c-food-s0', // 子類別 → 圖示取主類別 🍜
        merchant: '晨光早餐店',
        occurredAt: DateTime(2026, 10, 18, 8, 15).millisecondsSinceEpoch);
    await DbFixture.seedTx(db,
        id: 't3',
        kind: 'income',
        amountMinor: 50000,
        accountId: 'a-1',
        occurredAt: DateTime(2026, 10, 17, 12).millisecondsSinceEpoch);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    tester.view.physicalSize = const Size(500, 2400); // 窄（<900）→ 手機卡片
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light), home: const LedgerPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('今天 10/18'), findsOneWidget,
          reason: '分日標題（今天）');
      expect(find.textContaining('昨天 10/17'), findsOneWidget,
          reason: '分日標題（昨天）');
      expect(find.text('小計 -315'), findsOneWidget,
          reason: '當日小計＝淨額（-195-120；雛型 02）');
      expect(find.text('小計 50,000'), findsOneWidget, reason: '收入日小計為正');
      expect(find.byType(TxTile), findsNWidgets(3));
      // 標題＝分類（PM 2026-10-26）；副標＝時分 · 帳戶[ · 商家]（日期在分日標題）。
      expect(find.text('餐飲食品'), findsWidgets, reason: '標題＝分類（主類別）');
      expect(find.textContaining('09:12 · 現金 · 陽光超商'), findsOneWidget,
          reason: '副標＝時間 · 帳戶 · 商家');
      // 子類別列圖示取主類別 🍜；金額顏色（支出紅／收入綠）。
      expect(find.text('🍜'), findsNWidgets(2), reason: '分類圖示圓（子→主類別）');
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
          .toList();
      expect(texts.where((t) => t == '-195').length, 1,
          reason: '金額應唯一（實際文字：$texts）');
      expect(texts.where((t) => t == '+50,000').length, 1,
          reason: '收入金額應唯一');
      final red = tester
          .widgetList<Text>(find.byType(Text))
          .firstWhere((t) => t.data == '-195');
      expect(red.style?.color, AppTokens.light.danger, reason: '支出金額紅');
      final green = tester
          .widgetList<Text>(find.byType(Text))
          .firstWhere((t) => t.data == '+50,000');
      expect(green.style?.color, AppTokens.light.success, reason: '收入金額綠');
      expect(tester.takeException(), isNull);
    } finally {
      container.dispose();
      db.close();
    }
  });

  testWidgets('明細頁（桌面 ≥900px）：表格欄位（日期/類型/分類/商家/帳戶/金額）', (tester) async {
    Clock.freeze(DateTime(2026, 10, 18, 12));
    addTearDown(Clock.unfreeze);
    final db = DbFixture.create();
    await DbFixture.seedAccount(
        db, id: 'a-1', type: 'cash', name: '現金', opening: 0);
    await DbFixture.seedCategory(db,
        id: 'c-food', kind: 'expense', name: '餐飲食品');
    db.execute("UPDATE categories SET icon='🍜' WHERE id='c-food'");
    await DbFixture.seedTx(db,
        id: 't1',
        kind: 'expense',
        amountMinor: 195,
        accountId: 'a-1',
        category: 'c-food',
        merchant: '陽光超商',
        occurredAt: DateTime(2026, 10, 18, 9, 12).millisecondsSinceEpoch);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    tester.view.physicalSize = const Size(1600, 1000); // 寬 → 桌面表格
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light), home: const LedgerPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('交易明細'), findsOneWidget, reason: '08 雛型標題');
      for (final h in ['日期', '類型', '分類', '商家／對象', '帳戶', '金額']) {
        // '分類' 亦見於篩選列——以 findsWidgets（表格欄位存在即可）。
        expect(find.text(h), findsWidgets, reason: '表格欄位：$h');
      }
      expect(find.byKey(const Key('tx-row-t1')), findsOneWidget);
      expect(find.text('🍜 餐飲食品'), findsOneWidget, reason: '分類欄含圖示（主類別）');
      expect(find.text('陽光超商'), findsOneWidget, reason: '商家／對象欄');
      expect(find.text('-195'), findsOneWidget, reason: '金額右欄');
      expect(tester.takeException(), isNull);
    } finally {
      container.dispose();
      db.close();
    }
  });
}
