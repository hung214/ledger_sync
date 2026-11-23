import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/budgets/budget_evaluator.dart';
import 'package:ledger_sync/application/budgets/budget_service.dart';
import 'package:ledger_sync/application/quick_entry/save_transaction_use_case.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';

import '../../helpers/db_fixture.dart';

/// T71（PM 2026-11-24）：**主分類預算＝主分類＋其全部子分類加總**。
///
/// PM 例：早餐 100＋午餐 200 →「餐飲食品」主分類預算顯示 300。
/// 子分類預算維持精確比對；總預算（category_id NULL）口徑不變。
void main() {
  late AppDatabase db;
  late SaveTransactionUseCase save;

  setUp(() async {
    Clock.freeze(DateTime(2026, 11, 24, 12));
    db = DbFixture.create();
    await DbFixture.seedAccount(db, id: 'a-cash', type: 'cash', name: '現金');
    await DbFixture.seedCategory(db, id: 'c-food', kind: 'expense', name: '餐飲食品');
    await DbFixture.seedCategory(db,
        id: 'c-breakfast', kind: 'expense', name: '早餐', parentId: 'c-food');
    await DbFixture.seedCategory(db,
        id: 'c-lunch', kind: 'expense', name: '午餐', parentId: 'c-food');
    await DbFixture.seedCategory(db, id: 'c-other', kind: 'expense', name: '交通');
    save = SaveTransactionUseCase(db);
  });

  tearDown(() {
    Clock.unfreeze();
    db.close();
  });

  Future<void> spend(String categoryId, int amountMinor,
      {String settlementStatus = 'settled'}) async {
    save.execute(
      accountId: 'a-cash',
      categoryId: categoryId,
      amountMinor: amountMinor,
      occurredAt: Clock.now(),
      settlementStatus: settlementStatus,
    );
  }

  test('主分類預算用量＝主分類自身＋全部子分類加總（100+200=300）', () async {
    BudgetService(db, deviceId: 't')
        .setCategoryBudget(
            categoryId: 'c-food',
            amountMinor: 100000,
            periodStartDay: 1); // 1000 元
    await spend('c-breakfast', 10000); // 100 元
    await spend('c-lunch', 20000); // 200 元

    final usage = BudgetEvaluator(db).categoryUsage('c-food')!;
    expect(usage.totalMinor, 30000); // 早餐 100＋午餐 200 → 餐飲食品 300
  });

  test('主分類自身的直接交易也計入加總', () async {
    BudgetService(db, deviceId: 't')
        .setCategoryBudget(
            categoryId: 'c-food', amountMinor: 100000, periodStartDay: 1);
    await spend('c-food', 5000); // 50 元（記在主分類本身）
    await spend('c-lunch', 20000);

    final usage = BudgetEvaluator(db).categoryUsage('c-food')!;
    expect(usage.totalMinor, 25000); // 50 + 200
  });

  test('子分類預算維持精確比對（不含兄弟子分類）', () async {
    BudgetService(db, deviceId: 't')
        .setCategoryBudget(
            categoryId: 'c-breakfast', amountMinor: 50000, periodStartDay: 1);
    await spend('c-breakfast', 10000);
    await spend('c-lunch', 20000);

    final usage = BudgetEvaluator(db).categoryUsage('c-breakfast')!;
    expect(usage.totalMinor, 10000); // 只算早餐自身
  });

  test('其他主分類的交易不跨計', () async {
    BudgetService(db, deviceId: 't')
        .setCategoryBudget(
            categoryId: 'c-food', amountMinor: 100000, periodStartDay: 1);
    await spend('c-other', 99000);

    final usage = BudgetEvaluator(db).categoryUsage('c-food')!;
    expect(usage.totalMinor, 0);
  });

  test('pending 預扣照舊跨子分類合計', () async {
    BudgetService(db, deviceId: 't')
        .setCategoryBudget(
            categoryId: 'c-food', amountMinor: 100000, periodStartDay: 1);
    await spend('c-breakfast', 10000, settlementStatus: 'pending');
    await spend('c-lunch', 20000);

    final usage = BudgetEvaluator(db).categoryUsage('c-food')!;
    expect(usage.totalMinor, 30000);
    expect(usage.pendingMinor, 10000);
  });
}
