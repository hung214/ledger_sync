import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/presentation/screens/stats/category_donut.dart';
import 'package:ledger_sync/presentation/screens/stats/stats_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';

/// 統計頁護欄（PM 2026-10-26 整頁重做）：
/// ①**分類占比依「主類別」彙總**（子類別金額併入主類別，不同列）
/// ②三卡＝**底色＋外框**；甜甜圈＝`CategoryDonut`（百分比圈外引線）
/// ③月趨勢＝**白卡**；月份列＝三個外框元件。
/// ④**三卡可點選切換**（PM 2026-10-27）：支出／收入／淨額 → 圓餅與月趨勢**連動**。
void main() {
  Future<ProviderContainer> pump(WidgetTester tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedAccount(db, id: 'a-0', type: 'cash', name: '現金');
    // 主類別 餐飲食品（🍜）＋子類別 早餐／中餐；另一主類別 交通運輸。
    await DbFixture.seedCategory(
        db, id: 'c-food', kind: 'expense', name: '餐飲食品', isSystem: false);
    await DbFixture.seedCategory(
        db, id: 'c-food-s0', kind: 'expense', name: '早餐', parentId: 'c-food');
    await DbFixture.seedCategory(
        db, id: 'c-food-s1', kind: 'expense', name: '中餐', parentId: 'c-food');
    await DbFixture.seedCategory(
        db, id: 'c-transport', kind: 'expense', name: '交通運輸');
    final at = DateTime(2026, 10, 5, 12).millisecondsSinceEpoch;
    // 子類別兩筆（600＋100）＋主類別一筆（300）→ 主類別 餐飲食品應為 1,000。
    await DbFixture.seedTx(db,
        id: 't-1', kind: 'expense', amountMinor: 600, accountId: 'a-0',
        category: 'c-food-s0', occurredAt: at);
    await DbFixture.seedTx(db,
        id: 't-2', kind: 'expense', amountMinor: 100, accountId: 'a-0',
        category: 'c-food-s1', occurredAt: at);
    await DbFixture.seedTx(db,
        id: 't-3', kind: 'expense', amountMinor: 300, accountId: 'a-0',
        category: 'c-food', occurredAt: at);
    await DbFixture.seedTx(db,
        id: 't-4', kind: 'expense', amountMinor: 200, accountId: 'a-0',
        category: 'c-transport', occurredAt: at);
    await DbFixture.seedCategory(db, id: 'c-salary', kind: 'income', name: '薪資');
    await DbFixture.seedTx(db,
        id: 't-5', kind: 'income', amountMinor: 5000, accountId: 'a-0',
        category: 'c-salary', occurredAt: at);

    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light), home: const StatsPage()),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('① 分類占比**依主類別彙總**（子類別併入主類別，不另列）', (tester) async {
    await pump(tester);

    // 餐飲食品 = 600+100+300 = 1,000（占 1,200 的 83.3%）；交通運輸 = 200（16.7%）。
    expect(find.text('餐飲食品 83.3%'), findsOneWidget,
        reason: '子類別（早餐/中餐）金額併入主類別餐飲食品');
    expect(find.text('交通運輸 16.7%'), findsOneWidget);
    expect(find.text('早餐 50.0%'), findsNothing, reason: '子類別不得單獨出現');
    expect(find.text('中餐 8.3%'), findsNothing);
    expect(find.text('1,000'), findsOneWidget, reason: '主類別合計金額');
    expect(tester.takeException(), isNull);
  });

  testWidgets('② 三卡＝底色＋外框；甜甜圈存在（百分比圈外引線）', (tester) async {
    await pump(tester);

    expect(find.byKey(const Key('stats-donut')), findsOneWidget);
    expect(find.byType(CategoryDonut), findsOneWidget);
    expect(find.text('合計'), findsOneWidget);

    // 三卡：底色（track）＋外框（邊框非 null）。
    for (final label in ['支出', '收入', '淨額']) {
      final container = tester.widget<Container>(find
          .ancestor(of: find.text(label), matching: find.byType(Container))
          .first);
      final deco = container.decoration as BoxDecoration?;
      expect(deco?.border, isNotNull, reason: '$label 卡需有外框（PM 2026-10-26）');
      expect(deco?.color, isNotNull, reason: '$label 卡需有底色');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('③ 月份列三元件＋月趨勢白卡（含 {m}月 總計）', (tester) async {
    await pump(tester);

    expect(find.byKey(const Key('stats-month-prev')), findsOneWidget);
    expect(find.byKey(const Key('stats-month')), findsOneWidget);
    expect(find.byKey(const Key('stats-month-next')), findsOneWidget);
    expect(find.text('2026/10'), findsOneWidget);
    expect(find.text('期間（月份）'), findsOneWidget);
    expect(find.text('月趨勢（支出）'), findsOneWidget);
    expect(find.text('10月 1,200'), findsOneWidget);
    expect(find.text('分類占比（本月）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('④ 三卡可切換：收入／淨額 → 圓餅與月趨勢連動（PM 2026-10-27）', (tester) async {
    await pump(tester);

    // 預設＝支出（分類占比依主類別；月趨勢（支出））。
    expect(find.text('分類占比（本月）'), findsOneWidget);
    expect(find.text('月趨勢（支出）'), findsOneWidget);

    // 切「收入」→ 圓餅改列收入主類別；月趨勢改收入。
    await tester.tap(find.byKey(const Key('stats-metric-收入')));
    await tester.pumpAndSettle();
    expect(find.text('薪資 100.0%'), findsOneWidget, reason: '收入主類別占比');
    expect(find.text('餐飲食品 83.3%'), findsNothing, reason: '切換後不應再見支出分類');
    expect(find.text('月趨勢（收入）'), findsOneWidget);
    expect(find.text('10月 5,000'), findsOneWidget, reason: '月趨勢＝收入 5,000');

    // 切「淨額」→ 收支組成（收入／支出兩塊）＋圓心＝淨額；月趨勢＝淨額（可負）。
    await tester.tap(find.byKey(const Key('stats-metric-淨額')));
    await tester.pumpAndSettle();
    expect(find.text('收支組成（本月）'), findsOneWidget);
    expect(find.text('淨額'), findsWidgets, reason: '圓心標籤＝淨額');
    expect(find.text('+3,800'), findsWidgets, reason: '淨額＝5,000−1,200');
    expect(find.text('收入 80.6%'), findsOneWidget);
    expect(find.text('支出 19.4%'), findsOneWidget);
    expect(find.text('月趨勢（淨額）'), findsOneWidget);
    expect(find.text('10月 3,800'), findsOneWidget);

    // 切回「支出」→ 還原。
    await tester.tap(find.byKey(const Key('stats-metric-支出')));
    await tester.pumpAndSettle();
    expect(find.text('餐飲食品 83.3%'), findsOneWidget);
    expect(find.text('月趨勢（支出）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('⑤ 預設月份＝**最新有資料月份**（DBG-015：多月份時須排序）', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedAccount(db, id: 'a-0', type: 'cash', name: '現金');
    await DbFixture.seedCategory(db, id: 'c-food', kind: 'expense', name: '餐飲食品');
    await DbFixture.seedCategory(db, id: 'c-shop', kind: 'expense', name: '購物');
    // 先種「較新」再種「較舊」（測排序，而非插入順序）。
    await DbFixture.seedTx(db,
        id: 'new', kind: 'expense', amountMinor: 700, accountId: 'a-0',
        category: 'c-food',
        occurredAt: DateTime(2026, 10, 20, 12).millisecondsSinceEpoch);
    await DbFixture.seedTx(db,
        id: 'old', kind: 'expense', amountMinor: 300, accountId: 'a-0',
        category: 'c-shop',
        occurredAt: DateTime(2026, 9, 20, 12).millisecondsSinceEpoch);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light), home: const StatsPage()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('2026/10'), findsOneWidget, reason: '預設＝最新月（非插入順序）');
    expect(find.text('餐飲食品 100.0%'), findsOneWidget, reason: '10 月資料（700）');
    expect(find.text('購物 100.0%'), findsNothing, reason: '不應顯示 9 月資料');
    expect(find.text('10月 700'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('⑥ 累計結餘：**2 個月以上才出現**、值＝累計收支結餘', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedAccount(db, id: 'a-0', type: 'cash', name: '現金');
    await DbFixture.seedCategory(db, id: 'c-food', kind: 'expense', name: '餐飲食品');
    await DbFixture.seedCategory(db, id: 'c-salary', kind: 'income', name: '薪資');

    Future<void> pumpPage(WidgetTester t) async {
      final c = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
      ]);
      addTearDown(c.dispose);
      t.view.physicalSize = const Size(900, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
            theme: buildAppTheme(Brightness.light), home: const StatsPage()),
      ));
      await t.pumpAndSettle();
    }

    // 單月：**不應**出現累計結餘選項。
    await DbFixture.seedTx(db,
        id: 'oct', kind: 'expense', amountMinor: 200, accountId: 'a-0',
        category: 'c-food',
        occurredAt: DateTime(2026, 10, 10, 12).millisecondsSinceEpoch);
    await pumpPage(tester);
    expect(find.byKey(const Key('stats-metric-累計結餘')), findsNothing,
        reason: '只有 1 個月→不提供累計結餘（PM 2026-10-27）');

    // 加上第 2 個月：9 月 -300 → 累計 -300；10 月 +800 → 累計 +500。
    await DbFixture.seedTx(db,
        id: 'sep-e', kind: 'expense', amountMinor: 300, accountId: 'a-0',
        category: 'c-food',
        occurredAt: DateTime(2026, 9, 10, 12).millisecondsSinceEpoch);
    await DbFixture.seedTx(db,
        id: 'oct-i', kind: 'income', amountMinor: 1000, accountId: 'a-0',
        category: 'c-salary',
        occurredAt: DateTime(2026, 10, 10, 12).millisecondsSinceEpoch);
    await pumpPage(tester);
    expect(find.byKey(const Key('stats-metric-累計結餘')), findsOneWidget,
        reason: '2 個月以上→出現累計結餘');

    await tester.tap(find.byKey(const Key('stats-metric-累計結餘')));
    await tester.pumpAndSettle();
    expect(find.text('+500'), findsWidgets, reason: '累計結餘＝−300＋800');
    expect(find.text('收支組成（累計）'), findsOneWidget);
    expect(find.text('累計結餘'), findsWidgets, reason: '圓心標籤');
    expect(find.text('月趨勢（累計結餘）'), findsOneWidget);
    expect(find.text('9月 -300'), findsOneWidget, reason: '累計（9 月）');
    expect(find.text('10月 500'), findsOneWidget, reason: '累計（10 月）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('⑦ 月趨勢**最多顯示最近 12 個月**（並提示總月數）', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedAccount(db, id: 'a-0', type: 'cash', name: '現金');
    await DbFixture.seedCategory(db, id: 'c-food', kind: 'expense', name: '餐飲食品');
    // 13 個月：2025/10~2026/10；金額 100,200,…,1,300（最早月＝100，可辨識）。
    for (var i = 0; i < 13; i++) {
      await DbFixture.seedTx(db,
          id: 'm$i', kind: 'expense', amountMinor: 100 * (13 - i),
          accountId: 'a-0', category: 'c-food',
          occurredAt: DateTime(2026, 10 - i, 10, 12).millisecondsSinceEpoch);
    }
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light), home: const StatsPage()),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('僅顯示最近 12 個月（共 13 個月）'), findsOneWidget);
    expect(find.textContaining('月 ').evaluate().length, 12,
        reason: '明細列只列最近 12 個月');
    expect(find.text('10月 100'), findsNothing, reason: '最早月（2025/10）已排除');
    expect(find.text('10月 1,300'), findsOneWidget, reason: '最新月在列內');
    expect(tester.takeException(), isNull);
  });
}
