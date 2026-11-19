import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/presentation/screens/settings/account_settings_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';

/// PM 2026-11-19 回歸：「在設定新的帳戶，但是在總覽沒有帳戶」——
/// 帳戶 mutation 後 [activeAccountsProvider] 必須立即同步
/// （資料版本戳 dataVersionProvider：任何變更 → 全畫面刷新）。
void main() {
  testWidgets('帳戶管理新增帳戶 → activeAccountsProvider 即時可見', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const AccountSettingsPage()),
    ));
    await tester.pumpAndSettle();

    // 初始：活躍帳戶 0（快取）
    expect(container.read(activeAccountsProvider), isEmpty);

    // 開啟新增 sheet → 輸入名稱 → 儲存
    await tester.tap(find.byKey(const Key('acct-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('acct-name')), '薪轉帳戶');
    await tester.tap(find.byKey(const Key('acct-save')));
    await tester.pumpAndSettle();

    // **不用重啟**——provider 已隨版本戳重算（總覽/快記同步可見）
    final accounts = container.read(activeAccountsProvider);
    expect(accounts, hasLength(1), reason: '新帳戶必須立即出現（總覽/快記同源）');
    expect(accounts.first.name, '薪轉帳戶');
  });
}
