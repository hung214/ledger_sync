import '../../data/sqlite/app_database.dart';
import 'budget_period_service.dart';

/// 預算評估（SDD §5.3 BudgetEvaluator；FR-B 口徑）。
///
/// - 用量＝本期 expense（**含 pending 預扣**——承諾支出口徑，FR-B5/S5.3）；
///   預扣分量另計（明細標示用）。
/// - 收入達標率＝本期 income / 收入目標（四捨五入取整；≥100% 已達成，FR-B6）。
/// - 本月預計結餘＝收入目標 − 總預算（FR-B7；實際結餘另由 UI 以衍生值計）。
/// - 週期＝各預算自身 period_start_day（FR-B2；S5.6 跨月邊界）。
class BudgetEvaluator {
  const BudgetEvaluator(this._db);

  final AppDatabase _db;
  static const BudgetPeriodService _period = BudgetPeriodService();

  /// 分類預算用量（含 pending 分量）；無該分類預算回 null。
  ///
  /// **主分類預算＝主分類自身＋其全部子分類加總**（PM 2026-11-24：
  /// 早餐 100＋午餐 200 →「餐飲食品」預算顯示 300）；子分類預算＝
  /// 精確比對該子分類（不受主分類影響）。
  CategoryUsage? categoryUsage(String categoryId) {
    final budget = _budgetByCategory(categoryId);
    if (budget == null) return null;
    final period = _period.current(budget.periodStartDay);
    final ids = _selfAndChildIds(categoryId);
    var total = 0;
    var pending = 0;
    for (final t in _db.transactionsBetween(period.startMs, period.endExclusiveMs)) {
      if (t.kind != 'expense' || !ids.contains(t.categoryId)) continue;
      total += t.amountMinor;
      if (t.settlementStatus == 'pending') pending += t.amountMinor;
    }
    return CategoryUsage(
      totalMinor: total,
      pendingMinor: pending,
      budgetAmountMinor: budget.amountMinor,
    );
  }

  /// 該分類自身＋（若為主分類）其全部子分類的 id 集合。
  Set<String> _selfAndChildIds(String categoryId) {
    final ids = <String>{categoryId};
    for (final c in _db.categoriesByKind('expense')) {
      if (c.parentId == categoryId) ids.add(c.id);
    }
    return ids;
  }

  /// 總預算用量（全分類，含 pending；無總預算回 null）。
  int? totalUsageMinor() {
    final budget = _totalBudget();
    if (budget == null) return null;
    final period = _period.current(budget.periodStartDay);
    return _db
        .transactionsBetween(period.startMs, period.endExclusiveMs)
        .where((t) => t.kind == 'expense')
        .fold<int>(0, (sum, t) => sum + t.amountMinor);
  }

  /// 收入目標達標率（四捨五入 %）與是否達成；無目標回 null。
  IncomeGoalStatus? incomeGoalStatus() {
    final goal = _db.activeIncomeGoal();
    if (goal == null) return null;
    final period = _period.current(goal.periodStartDay);
    final achievedMinor = _db
        .transactionsBetween(period.startMs, period.endExclusiveMs)
        .where((t) => t.kind == 'income')
        .fold<int>(0, (sum, t) => sum + t.amountMinor);
    final rate =
        goal.amountMinor <= 0 ? 0 : (achievedMinor * 100 / goal.amountMinor).round();
    return IncomeGoalStatus(
      ratePercent: rate,
      achieved: goal.amountMinor > 0 && achievedMinor >= goal.amountMinor,
      achievedMinor: achievedMinor,
      goalMinor: goal.amountMinor,
    );
  }

  /// 本月預計結餘＝收入目標 − 總預算（FR-B7）；任一未設定回 null。
  int? plannedBalanceMinor() {
    final goal = _db.activeIncomeGoal();
    final totalBudget = _totalBudget();
    if (goal == null || totalBudget == null) return null;
    return goal.amountMinor - totalBudget.amountMinor;
  }

  /// 目前週期（顯示用；取分類預算自身起始日）。
  BudgetPeriod? categoryPeriod(String categoryId) {
    final budget = _budgetByCategory(categoryId);
    if (budget == null) return null;
    return _period.current(budget.periodStartDay);
  }

  BudgetRow? _budgetByCategory(String categoryId) {
    for (final b in _db.allBudgets()) {
      if (b.categoryId == categoryId) return b;
    }
    return null;
  }

  BudgetRow? _totalBudget() {
    for (final b in _db.allBudgets()) {
      if (b.categoryId == null) return b;
    }
    return null;
  }
}

/// 分類預算用量（FR-B5：含 pending 預扣＋分量可辨識）。
class CategoryUsage {
  const CategoryUsage({
    required this.totalMinor,
    required this.pendingMinor,
    required this.budgetAmountMinor,
  });

  /// 本期承諾支出合計（含 pending 預扣）。
  final int totalMinor;

  /// 其中預扣（settlement=pending）分量。
  final int pendingMinor;
  final int budgetAmountMinor;
}

/// 收入目標狀態（FR-B6；S5.4 達標率 >100% 不封頂）。
class IncomeGoalStatus {
  const IncomeGoalStatus({
    required this.ratePercent,
    required this.achieved,
    required this.achievedMinor,
    required this.goalMinor,
  });

  final int ratePercent;
  final bool achieved;
  final int achievedMinor;
  final int goalMinor;
}
