import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/presentation/screens/quick_entry/quick_entry_controller.dart';

import '../helpers/db_fixture.dart';

/// 「子類別帶入」（PM 2026-11-21）：選分類 → 自動帶入**同分類最後一筆
/// 交易**的商家＋金額（涵蓋掃描/匯入等非快記入帳——記憶只記快記流程）。
void main() {
  test('選子類別 → 帶入同分類最後一筆交易的商家＋金額（新筆優先）', () {
    final db = DbFixture.create();
    addTearDown(db.close);
    final day = DateTime(2026, 11, 21, 9);
    DbFixture.seedAccount(db, id: 'a-1', type: 'cash', name: '現金');
    DbFixture.seedCategory(db, id: 'c-main', kind: 'expense', name: '餐飲');
    DbFixture.seedCategory(db,
        id: 'c-sub', kind: 'expense', name: '咖啡', parentId: 'c-main');
    DbFixture.seedTx(db,
        id: 't-old',
        kind: 'expense',
        amountMinor: 100,
        accountId: 'a-1',
        category: 'c-sub',
        merchant: '晨光咖啡',
        occurredAt: day.subtract(const Duration(days: 1)).millisecondsSinceEpoch);
    DbFixture.seedTx(db,
        id: 't-new',
        kind: 'expense',
        amountMinor: 245,
        accountId: 'a-1',
        category: 'c-sub',
        merchant: '陽光超商',
        occurredAt: day.millisecondsSinceEpoch);

    final container =
        ProviderContainer(overrides: [dbProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);
    // listen 保活（AutoDisposeNotifier——read 即棄會重建狀態）。
    final sub = container.listen(quickEntryControllerProvider, (_, _) {});
    addTearDown(sub.close);

    container.read(quickEntryControllerProvider.notifier).selectCategoryById('c-sub');
    final state = container.read(quickEntryControllerProvider);
    expect(state.amount, '245', reason: '帶入最後一筆（較新）的金額');
    expect(state.merchant, '陽光超商');
  });

  test('同分類無任何交易 → 不帶入（金額留空、無商家）', () {
    final db = DbFixture.create();
    addTearDown(db.close);
    DbFixture.seedAccount(db, id: 'a-1', type: 'cash', name: '現金');
    DbFixture.seedCategory(db, id: 'c-main', kind: 'expense', name: '餐飲');

    final container =
        ProviderContainer(overrides: [dbProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);
    final sub = container.listen(quickEntryControllerProvider, (_, _) {});
    addTearDown(sub.close);

    container
        .read(quickEntryControllerProvider.notifier)
        .selectCategoryById('c-main');
    final state = container.read(quickEntryControllerProvider);
    expect(state.amount, '');
    expect(state.merchant, '');
  });
}
