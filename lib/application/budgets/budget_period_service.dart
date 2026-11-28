import '../../core/clock.dart';

/// 預算週期（FR-B2：period_start_day 1..28 → 本期起訖；S5.6 跨月語意）。
///
/// now.day >= startDay → 本月 startDay 起；否則上月 startDay 起。
/// 端點：[startMs] 含、[endExclusiveMs] 不含（顯示端為 end − 1 日）。
class BudgetPeriod {
  const BudgetPeriod({required this.startMs, required this.endExclusiveMs});

  final int startMs;
  final int endExclusiveMs;

  /// 含端顯示（S5.6：2026/05/25 ~ 2026/06/24）。
  String display() {
    final start = DateTime.fromMillisecondsSinceEpoch(startMs);
    final endInclusive = DateTime.fromMillisecondsSinceEpoch(endExclusiveMs)
        .subtract(const Duration(days: 1));
    String f(DateTime d) =>
        '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
    return '${f(start)} ~ ${f(endInclusive)}';
  }
}

class BudgetPeriodService {
  const BudgetPeriodService();

  BudgetPeriod periodOf(int startDay, DateTime now) {
    final DateTime start;
    if (now.day >= startDay) {
      start = DateTime(now.year, now.month, startDay);
    } else {
      start = DateTime(now.year, now.month - 1, startDay);
    }
    final end = DateTime(start.year, start.month + 1, startDay);
    return BudgetPeriod(
      startMs: start.millisecondsSinceEpoch,
      endExclusiveMs: end.millisecondsSinceEpoch,
    );
  }

  /// 當前時間之週期（Clock 單一時間來源）。
  BudgetPeriod current(int startDay) => periodOf(startDay, Clock.now());

  /// 指定月份**起算**的週期（start＝該月 startDay；預算頁月份選擇——
  /// PM 2026-11-28）。與 [periodOf]（含 now 的週期）不同：monthAnchor 為
  /// 週期起始月錨點（檢視 M 月＝M 月 startDay 起的那個週期）。
  BudgetPeriod periodOfStartMonth(int startDay, DateTime monthAnchor) {
    final start = DateTime(monthAnchor.year, monthAnchor.month, startDay);
    final end = DateTime(start.year, start.month + 1, startDay);
    return BudgetPeriod(
      startMs: start.millisecondsSinceEpoch,
      endExclusiveMs: end.millisecondsSinceEpoch,
    );
  }
}
