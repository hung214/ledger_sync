import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/first_run_bootstrap.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/presentation/screens/quick_entry/quick_entry_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';

/// 快記**手機版版面**回歸護欄（PM 2026-10-25：「顯示不正確」——對齊雛型 03／10）。
///
/// 契約：
/// ①**無三欄快捷格**（分類不再平鋪；改由「分類」欄 → 彈窗）——三欄格僅桌面面板（08）。
/// ②鍵盤第一排 **C／⌫／OK（OK 跨兩格）**＝4 格對齊。
/// ③**帳戶｜分類 同一列兩欄**；欄位順序：模式 → 金額 → 日期 → 帳戶/分類 → 商家 → 備註。
/// ④金額**右對齊**＋下方說明「金額（TWD・整數元）」。
void main() {
  Future<void> pump(WidgetTester tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await FirstRunBootstrap.seedIfNeeded(db);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1080, 2400); // 500 邏輯寬（<900＝手機殼）
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const QuickEntryPage()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('① 手機版**無**三欄快捷格（分類＝欄位→彈窗）', (tester) async {
    await pump(tester);

    expect(find.byKey(const Key('cat-grid-餐飲食品')), findsNothing,
        reason: 'PM 2026-10-25：兩平台皆**不符**平鋪主類別——分類＝欄位→彈窗');
    expect(find.byKey(const Key('quick-entry-category')), findsOneWidget,
        reason: '分類欄仍在（點選開彈窗）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('② 鍵盤第一排 OK **跨兩格**（＝4 格對齊）', (tester) async {
    await pump(tester);

    final ok = tester.getSize(find.byKey(const Key('quick-entry-save')));
    final key7 = tester.getSize(find.byKey(const Key('keypad-7')));
    expect(ok.width, greaterThan(key7.width * 1.7),
        reason: 'OK 跨兩格（grid-column:span 2）——第一排 C／⌫／OK 共 4 格');
    expect(find.byKey(const Key('keypad-C')), findsOneWidget);
    expect(find.byKey(const Key('keypad-⌫')), findsOneWidget);
    expect(find.byKey(const Key('keypad-＝')), findsNothing, reason: '無「＝」鍵');
    expect(tester.takeException(), isNull);
  });

  testWidgets('③④ 帳戶｜分類同列兩欄＋金額置中＋欄位順序', (tester) async {
    await pump(tester);

    // 同列：兩欄垂直中心相同（同一 Row）。
    final acct = tester.getCenter(find.byKey(const Key('quick-entry-account')));
    final cat = tester.getCenter(find.byKey(const Key('quick-entry-category')));
    expect((acct.dy - cat.dy).abs() < 1.0, isTrue,
        reason: '帳戶／分類同一列（原型 10）');
    expect(acct.dx, lessThan(cat.dx), reason: '帳戶在左、分類在右');

    // 順序：金額 < 日期 < 帳戶/分類 < 商家 < 備註。
    double top(Key k) => tester.getTopLeft(find.byKey(k)).dy;
    expect(top(const Key('quick-entry-amount')),
        lessThan(top(const Key('quick-entry-time'))));
    expect(top(const Key('quick-entry-time')),
        lessThan(top(const Key('quick-entry-account'))));
    expect(top(const Key('quick-entry-category')),
        lessThan(top(const Key('quick-entry-merchant'))));
    expect(top(const Key('quick-entry-merchant')),
        lessThan(top(const Key('quick-entry-note'))));

    // 金額**置中**（03 雛型；PM 2026-10-25：手機版以 03 為準）＋帳戶 Sticky 小字。
    final field = tester.widget<TextField>(
        find.byKey(const Key('quick-entry-amount')));
    expect(field.textAlign, TextAlign.center);
    expect(find.textContaining('（Sticky）'), findsOneWidget,
        reason: '金額下方小字＝帳戶（03 雛型）');
    // 商家／備註為**輸入欄位**（03 雛型；PM 2026-10-25）。
    expect(tester.widget<TextField>(find.byKey(const Key('quick-entry-merchant'))),
        isA<TextField>());
    expect(tester.takeException(), isNull);
  });

  testWidgets('轉帳模式：來源｜目標帳戶同列；分類／商家顯示不適用', (tester) async {
    await pump(tester);

    await tester.tap(find.text('轉帳'));
    await tester.pumpAndSettle();

    final src = tester.getCenter(find.byKey(const Key('quick-entry-account')));
    final dst = tester.getCenter(find.byKey(const Key('quick-entry-target')));
    expect((src.dy - dst.dy).abs() < 1.0, isTrue,
        reason: '來源／目標帳戶同一列');
    expect(find.byKey(const Key('quick-entry-category')), findsNothing);
    expect(find.byKey(const Key('quick-entry-merchant')), findsNothing);
    expect(find.text('不適用（轉帳語意）'), findsOneWidget);
    expect(find.byKey(const Key('cat-grid-餐飲食品')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
