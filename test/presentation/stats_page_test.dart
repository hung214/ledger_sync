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
    await DbFixture.seedTx(db,
        id: 't-5', kind: 'income', amountMinor: 5000, accountId: 'a-0',
        occurredAt: at);

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
}
