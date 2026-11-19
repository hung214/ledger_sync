import '../../data/sqlite/app_database.dart';

/// CSV 匯出（FR-R4；acceptance S10.3）。
///
/// - **UTF-8 with BOM**（EF BB BF）——Windows Excel 直接開啟中文不亂碼。
/// - 欄位：日期/時間、類型、金額、幣別、帳戶、轉入帳戶、分類、商家、備註、標籤、source
///   （S10.3-3＋PM 2026-11-19 來回相容：轉帳列需轉入帳戶；標籤 M2 未使用輸出空值）。
/// - 金額欄為**major 單位兩位小數**（`1.00`＝1 元；PM 2026-11-19 來回相容決策：
///   舊版寫 minor，再匯入被當 major ×100——金額全錯）。Excel 可讀可 SUM。
/// - 欄值含逗號/引號/換行 → CSV 標準逸出（雙引號包裹＋引號加倍）。
class CsvExporter {
  const CsvExporter({
    this.categoryName,
    this.accountName,
  });

  final String Function(String id)? categoryName;
  final String Function(String id)? accountName;

  static const List<String> header = [
    '日期/時間', '類型', '金額', '幣別', '帳戶', '轉入帳戶', '分類', '商家', '備註', '標籤', 'source',
  ];

  String export(List<TxRow> txs) {
    final buf = StringBuffer('\uFEFF'); // UTF-8 BOM（EF BB BF）
    buf.writeln(header.map(_escape).join(','));
    for (final t in txs) {
      final dt = DateTime.fromMillisecondsSinceEpoch(t.occurredAt);
      final date = '${dt.year}/${dt.month.toString().padLeft(2, '0')}/'
          '${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      final cells = [
        date,
        t.kind,
        (t.amountMinor / 100).toStringAsFixed(2), // major 兩位小數（匯入引擎互逆）
        t.currency,
        accountName?.call(t.accountId) ?? t.accountId,
        t.toAccountId == null
            ? ''
            : (accountName?.call(t.toAccountId!) ?? t.toAccountId!),
        t.categoryId == null ? '' : (categoryName?.call(t.categoryId!) ?? t.categoryId!),
        t.merchant ?? '',
        t.note ?? '',
        '', // 標籤（M2 未使用）
        t.source,
      ];
      buf.writeln(cells.map(_escape).join(','));
    }
    return buf.toString();
  }

  String _escape(String cell) {
    if (cell.contains(',') || cell.contains('"') || cell.contains('\n')) {
      return '"${cell.replaceAll('"', '""')}"';
    }
    return cell;
  }
}
