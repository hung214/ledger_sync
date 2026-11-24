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

  // ── 帶入守衛（T72，PM 2026-11-24）：金額非 0 → 不帶入 ──

  test('金額已輸入（非 0）→ 切分類不帶入上次資料（金額/商家維持已輸入）', () {
    final db = DbFixture.create();
    addTearDown(db.close);
    final day = DateTime(2026, 11, 24, 9);
    DbFixture.seedAccount(db, id: 'a-1', type: 'cash', name: '現金');
    DbFixture.seedCategory(db, id: 'c-a', kind: 'expense', name: '甲');
    DbFixture.seedCategory(db, id: 'c-b', kind: 'expense', name: '乙');
    DbFixture.seedTx(db,
        id: 't-b',
        kind: 'expense',
        amountMinor: 245,
        accountId: 'a-1',
        category: 'c-b',
        merchant: '舊商家',
        occurredAt: day.millisecondsSinceEpoch);

    final container =
        ProviderContainer(overrides: [dbProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);
    final sub = container.listen(quickEntryControllerProvider, (_, _) {});
    addTearDown(sub.close);
    final ctrl = container.read(quickEntryControllerProvider.notifier);

    // 使用者先輸入金額 500，再選有歷史資料的分類乙。
    ctrl.setAmount('500');
    ctrl.selectCategoryById('c-b');

    final state = container.read(quickEntryControllerProvider);
    expect(state.amount, '500', reason: '金額非 0 → 不被上次資料（245）覆蓋');
    expect(state.merchant, '', reason: '商家也一併不帶入');
  });

  test('金額為 0 → 切分類照舊帶入最後一筆交易', () {
    final db = DbFixture.create();
    addTearDown(db.close);
    final day = DateTime(2026, 11, 24, 9);
    DbFixture.seedAccount(db, id: 'a-1', type: 'cash', name: '現金');
    DbFixture.seedCategory(db, id: 'c-a', kind: 'expense', name: '甲');
    DbFixture.seedCategory(db, id: 'c-b', kind: 'expense', name: '乙');
    DbFixture.seedTx(db,
        id: 't-b',
        kind: 'expense',
        amountMinor: 245,
        accountId: 'a-1',
        category: 'c-b',
        merchant: '舊商家',
        occurredAt: day.millisecondsSinceEpoch);

    final container =
        ProviderContainer(overrides: [dbProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);
    final sub = container.listen(quickEntryControllerProvider, (_, _) {});
    addTearDown(sub.close);
    final ctrl = container.read(quickEntryControllerProvider.notifier);

    ctrl.selectCategoryById('c-b'); // 帶入 245
    ctrl.setAmount('0'); // 金額歸 0
    ctrl.selectCategoryById('c-a'); // 切到甲（無交易）
    ctrl.selectCategoryById('c-b'); // 再切回乙

    final state = container.read(quickEntryControllerProvider);
    expect(state.amount, '245', reason: '金額 0 → 照舊帶入');
    expect(state.merchant, '舊商家');
  });
}
