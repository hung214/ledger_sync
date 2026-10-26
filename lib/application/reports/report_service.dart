import '../../data/sqlite/app_database.dart';

/// 報表聚合（FR-R2；acceptance S10.1；SDD 報表域）。
///
/// - 僅計 **kind=expense**（轉帳/收入不計入支出——S10.1 失敗判定 Critical）。
/// - 期間＝指定年月（YYYY/MM）；墓標排除（transactionsBetween 保證）。
/// - 百分比四捨五入至 **0.1%**（toStringAsFixed(1)；S10.1 通過標準）。
class ReportService {
  const ReportService(this._db);

  final AppDatabase _db;

  ReportAggregate aggregate(int year, int month) {
    final start = DateTime(year, month).millisecondsSinceEpoch;
    final end = DateTime(year, month + 1).millisecondsSinceEpoch;
    final byCategory = <String?, int>{};
    var total = 0;
    for (final t in _db.transactionsBetween(start, end)) {
      if (t.kind != 'expense') continue;
      byCategory[t.categoryId] = (byCategory[t.categoryId] ?? 0) + t.amountMinor;
      total += t.amountMinor;
    }
    final shares = byCategory.entries
        .map((e) => CategoryShare(
              name: e.key == null ? '未分類' : (_db.categoryName(e.key!) ?? '未分類'),
              amountMinor: e.value,
              percentText:
                  total <= 0 ? '0.0' : (e.value * 100 / total).toStringAsFixed(1),
            ))
        .toList()
      ..sort((a, b) => b.amountMinor.compareTo(a.amountMinor));
    return ReportAggregate(year: year, month: month, totalMinor: total, shares: shares);
  }

  /// 依**主類別**彙總（PM 2026-10-26；統計頁分類占比＝**主類別**，對齊 11-stats 雛型）：
  /// 子類別金額**併入其所屬主類別**（子類別不再各自列出）；未分類＝「未分類」。
  /// 其餘語意同 [aggregate]（僅 expense／墓標排除／0.1% 四捨五入／降冪）。
  ReportAggregate aggregateByMain(int year, int month) {
    final start = DateTime(year, month).millisecondsSinceEpoch;
    final end = DateTime(year, month + 1).millisecondsSinceEpoch;
    final byMain = <String?, int>{};
    var total = 0;
    for (final t in _db.transactionsBetween(start, end)) {
      if (t.kind != 'expense') continue;
      byMain[_mainIdOf(t.categoryId)] =
          (byMain[_mainIdOf(t.categoryId)] ?? 0) + t.amountMinor;
      total += t.amountMinor;
    }
    final shares = byMain.entries
        .map((e) => CategoryShare(
              name: e.key == null ? '未分類' : (_db.categoryName(e.key!) ?? '未分類'),
              amountMinor: e.value,
              percentText:
                  total <= 0 ? '0.0' : (e.value * 100 / total).toStringAsFixed(1),
            ))
        .toList()
      ..sort((a, b) => b.amountMinor.compareTo(a.amountMinor));
    return ReportAggregate(year: year, month: month, totalMinor: total, shares: shares);
  }

  /// 分類 id → **主類別** id（主類別＝自身；子類別＝parent；未分類＝null）。
  String? _mainIdOf(String? categoryId) {
    if (categoryId == null) return null;
    final row = _db.categoryById(categoryId);
    return row?.parentId ?? categoryId;
  }
}

/// 聚合結果（分類占比降冪＋總計）。
class ReportAggregate {
  const ReportAggregate({
    required this.year,
    required this.month,
    required this.totalMinor,
    required this.shares,
  });

  final int year;
  final int month;
  final int totalMinor;
  final List<CategoryShare> shares;

  CategoryShare? shareOf(String categoryName) {
    for (final s in shares) {
      if (s.name == categoryName) return s;
    }
    return null;
  }
}

class CategoryShare {
  const CategoryShare({
    required this.name,
    required this.amountMinor,
    required this.percentText,
  });

  final String name;
  final int amountMinor;

  /// 四捨五入至 0.1%（如 '69.2'）。
  final String percentText;
}
