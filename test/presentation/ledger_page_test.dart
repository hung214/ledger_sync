import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/presentation/screens/ledger/ledger_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';

/// 明細頁（P2 雛型整合）快速護欄：帳戶 chips＋收支性質篩選 chips 之行爲。
/// **跑在純 Dart VM（~1 秒）**——同批斷言若走 integration_test 需 ~15 秒且要
/// macOS app 實例（PM 2026-10-22：前後端測試分流以縮短回饋迴圈）。
void main() {
  testWidgets('明細：收支性質 chips 篩選（全部/支出/收入/轉帳）', (tester) async {
    final db = DbFixture.create();
    await DbFixture.seedAccount(db, id: 'a-0', type: 'cash', name: '現金');
    await DbFixture.seedAccount(db, id: 'a-1', type: 'bank', name: '銀行');
    await DbFixture.seedTx(
      db,
      id: 't-e',
      kind: 'expense',
      amountMinor: 100,
      accountId: 'a-0',
      merchant: '早餐店',
      occurredAt: 1700000000000,
    );
    await DbFixture.seedTx(
      db,
      id: 't-i',
      kind: 'income',
      amountMinor: 5000,
      accountId: 'a-1',
      merchant: '薪水',
      occurredAt: 1700000060000,
    );
    await DbFixture.seedTx(
      db,
      id: 't-t',
      kind: 'transfer',
      amountMinor: 300,
      accountId: 'a-1',
      toAccountId: 'a-0',
      occurredAt: 1700000120000,
    );
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const LedgerPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 期間＝**月份制**（PM 2026-10-24）：預設本月——本測試資料為 2023/11，
      // 先切「全部月份」再驗收支 chips（聚焦本測試主題）。
      expect(find.byKey(const Key('month-prev')), findsOneWidget);
      expect(find.byKey(const Key('month-next')), findsOneWidget);
      await tester.tap(find.byKey(const Key('filter-period')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部月份').last);
      await tester.pumpAndSettle();

      // 全部：三筆（P2 預設不改變既有交集語意）。
      expect(find.byType(ListTile), findsNWidgets(3));
      expect(tester.takeException(), isNull);

      // 支出：僅 1 筆。
      await tester.tap(find.byKey(const Key('kind-chip-支出')));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.textContaining('早餐店'), findsWidgets);

      // 轉帳：僅 1 筆（跨帳戶語意）。
      await tester.tap(find.byKey(const Key('kind-chip-轉帳')));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsOneWidget);

      // 回全部：三筆。
      await tester.tap(find.byKey(const Key('kind-chip-全部')));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNWidgets(3));

      // 帳戶 chip（現金）：支出 1＋轉入 1＝2 筆。
      await tester.tap(find.byKey(const Key('acct-chip-a-0')));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNWidgets(2));

      expect(tester.takeException(), isNull);
    } finally {
      db.close();
      container.dispose();
    }
  });

  /// PM 2026-11-27：帳戶/金額 chips 於手機視窗（390 寬）不得直排——
  /// 帳戶名＋應付金額為長字串，若被約束窄寬會逐字折行。以 chip 高度（單行）
  /// 與無 overflow 例外雙重驗證。
  testWidgets('明細：帳戶 chips 於手機視窗不直排（390 寬）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = DbFixture.create();
    await DbFixture.seedAccount(db, id: 'a-c', type: 'credit', name: '晨光範例卡');
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const LedgerPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final label = find.textContaining('應付');
      expect(label, findsOneWidget);
      final h = tester.getSize(label).height;
      expect(h, lessThan(22), reason: '帳戶/金額 chip 應單行（未直排）');
      expect(tester.takeException(), isNull, reason: '不得 overflow');
    } finally {
      container.dispose();
      db.close();
    }
  });

  /// PM 2026-11-27：多帳戶超出右緣 → 水平滑動可達最後一顆
  /// （chips 依文字自適應寬、非寫死寬度）。
  testWidgets('明細：多帳戶 chips 可水平滑動（依文字自適應）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = DbFixture.create();
    await DbFixture.seedAccount(db, id: 'a-0', type: 'cash', name: '現金');
    await DbFixture.seedAccount(db, id: 'a-1', type: 'bank', name: '銀行帳戶');
    await DbFixture.seedAccount(db, id: 'a-2', type: 'credit', name: '晨光範例卡');
    await DbFixture.seedAccount(db, id: 'a-3', type: 'credit', name: '示例卡');
    await DbFixture.seedAccount(
      db,
      id: 'a-4',
      type: 'ewallet',
      name: '票證卡（儲值語意）',
    );
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const LedgerPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 水平 ListView 懶載：視窗外 chips 未建（find 不到）——向左滑動後
      // 才會建出並進入視窗（證明可滑動、chips 依文字自適應寬）。
      await tester.drag(find.byType(ListView).first, const Offset(-400, 0));
      await tester.pumpAndSettle();
      final last = find.textContaining('票證卡');
      expect(last, findsOneWidget);
      expect(
        tester.getRect(last).right,
        lessThanOrEqualTo(390),
        reason: '水平滑動後應可達最後一顆帳戶',
      );
      expect(tester.takeException(), isNull);
    } finally {
      container.dispose();
      db.close();
    }
  });
}
