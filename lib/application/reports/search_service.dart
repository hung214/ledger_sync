import '../../core/text_index.dart';
import '../../data/sqlite/app_database.dart';

/// 交易搜尋／複合篩選（FR-R3；acceptance S10.2）。
///
/// - 關鍵字：FTS5 bigram（[TextIndex.bigram] 同函式產生查詢字串）——
///   環境缺 FTS5 或查詢失敗 → **降級 LIKE**（note/merchant 含片語）。
/// - 條件皆為 **AND 語意**（期間／分類／帳戶／金額區間，S10.2-2~4）。
/// - 排除墓標（deleted_at IS NULL 由來源查詢保證）；時間降冪。
/// - 關鍵字標準化：trim＋壓縮空白（S10.2 邊界：「陽光」與「陽光 」同結果）。
class SearchService {
  const SearchService(this._db);

  final AppDatabase _db;

  List<TxRow> search({
    String? keyword,
    int? startMs,
    int? endMs,
    String? categoryId,
    String? accountId,
    int? minMinor,
    int? maxMinor,
  }) {
    final kw = _normalize(keyword);
    List<TxRow> rows;
    if (kw != null && kw.isNotEmpty) {
      final match = TextIndex.matchQuery(kw);
      final refs = match == null ? null : _db.ftsSearch(match);
      if (refs != null) {
        rows = _db.transactionsByRowids(refs);
      } else {
        rows = _db.transactionsContaining(kw);
      }
      // **擴大搜尋範圍**（PM 2026-11-23 實測：22 筆中 19 筆無商家/備註——
      // 只搜 merchant/note 等於沒效果）：**分類名稱／帳戶名稱／金額（元）**。
      final catNames = {
        for (final c in [
          ..._db.categoriesByKind('expense'),
          ..._db.categoriesByKind('income'),
        ])
          c.id: c.name,
      };
      final accNames = {for (final a in _db.allAccounts()) a.id: a.name};
      final catIds = {
        for (final e in catNames.entries)
          if (e.value.contains(kw)) e.key,
      };
      final accIds = {
        for (final e in accNames.entries)
          if (e.value.contains(kw)) e.key,
      };
      final amountMinor =
          int.tryParse(kw) == null ? null : int.parse(kw) * 100;
      if (catIds.isNotEmpty || accIds.isNotEmpty || amountMinor != null) {
        final byId = {for (final r in rows) r.id: r};
        for (final t in _db
            .select('SELECT * FROM transactions WHERE deleted_at IS NULL')
            .map(TxRow.fromRow)) {
          final hit = (t.categoryId != null && catIds.contains(t.categoryId)) ||
              accIds.contains(t.accountId) ||
              (t.toAccountId != null && accIds.contains(t.toAccountId)) ||
              (amountMinor != null && t.amountMinor == amountMinor);
          if (hit) byId.putIfAbsent(t.id, () => t);
        }
        rows = byId.values.toList();
      }
    } else {
      rows = _db.transactionsBetween(
        startMs ?? 0,
        endMs ?? DateTime(9999).millisecondsSinceEpoch,
      );
    }
    return rows.where((t) {
      if (t.deletedAt != null) return false;
      if (startMs != null && t.occurredAt < startMs) return false;
      if (endMs != null && t.occurredAt >= endMs) return false;
      if (categoryId != null && t.categoryId != categoryId) return false;
      if (accountId != null && t.accountId != accountId) return false;
      if (minMinor != null && t.amountMinor < minMinor) return false;
      if (maxMinor != null && t.amountMinor > maxMinor) return false;
      return true;
    }).toList()
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  }

  /// 標準化：trim＋連續空白壓為單一空白。
  String? _normalize(String? keyword) {
    if (keyword == null) return null;
    final collapsed = keyword.trim().replaceAll(RegExp(r'\s+'), ' ');
    return collapsed.isEmpty ? null : collapsed;
  }
}
