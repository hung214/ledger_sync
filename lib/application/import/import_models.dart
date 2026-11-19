/// AndroMoney 匯入——領域模型（I3；tasks §6.0；PM 2026-11-16 決策）。
///
/// 設計原則：**parser 純函式**（CSV→草稿，不觸 DB）；`ImportService` 負責
/// DB 互動（preview 統計／apply 落地）。壞列不擋整批（逐列錯誤）。
library;

/// 交易類型（AndroMoney Type 欄對映）。
enum ImportKind { expense, income, transfer }

/// 單列匯入草稿（已解析成功；金額一律**正數** minor，方向由 [kind] 表達）。
class ImportRow {
  const ImportRow({
    required this.lineNo,
    required this.kind,
    required this.date,
    required this.amountMinor,
    required this.currency,
    required this.account,
    this.toAccount,
    this.category,
    this.subcategory,
    this.merchant,
    this.note,
  });

  final int lineNo;
  final ImportKind kind;
  final DateTime date;
  final int amountMinor;
  final String currency;
  final String account;
  final String? toAccount;
  final String? category;
  final String? subcategory;
  final String? merchant;
  final String? note;

  /// 去重鍵（PM 2026-11-16 決策：**日期＋金額＋備註＋帳戶**）。
  String get dedupKey =>
      '${date.year}-${date.month}-${date.day}|$amountMinor|$account|${note ?? ''}';
}

/// 逐列錯誤（壞列略過並回報，不擋整批）。
class ImportError {
  const ImportError({required this.lineNo, required this.reason});
  final int lineNo;
  final String reason;
}

/// 預覽統計（I4「選檔→預覽/乾跑」畫面呈現用）。
class ImportPreview {
  const ImportPreview({
    required this.rows,
    required this.errors,
    required this.skippedCurrency,
    required this.duplicateLines,
    required this.totalsMinor,
    required this.minDate,
    required this.maxDate,
    required this.newAccounts,
    required this.newMainCategories,
    required this.newSubCategories,
  });

  /// 可匯入列（去重後）。
  final List<ImportRow> rows;

  /// 解析失敗列（略過）。
  final List<ImportError> errors;

  /// 非 TWD 列（略過——多幣別語意未定，SP-x；報告標示）。
  final List<ImportRow> skippedCurrency;

  /// 重複列之行號（對 DB 或檔內；DedupKey 命中）。
  final List<int> duplicateLines;

  /// 各類型金額合計（minor）。
  final Map<ImportKind, int> totalsMinor;

  final DateTime? minDate;
  final DateTime? maxDate;

  /// DB 無 → apply 將自動建立之帳戶名。
  final Set<String> newAccounts;

  /// DB 無 → 將自動建立之**主分類**（kind → 名稱集）。
  final Map<String, Set<String>> newMainCategories;

  /// DB 無 → 將自動建立之**子分類**（主分類名 → 子名集）。
  final Map<String, Set<String>> newSubCategories;
}

/// apply 結果報告。
class ImportReport {
  const ImportReport({
    required this.inserted,
    required this.transfersInserted,
    required this.skippedDuplicate,
    required this.errorRows,
    required this.skippedCurrencyRows,
    required this.accountsCreated,
    required this.categoriesCreated,
    this.overwritten = 0,
  });

  final int inserted;
  final int transfersInserted;
  final int skippedDuplicate;
  final int errorRows;
  final int skippedCurrencyRows;
  final int accountsCreated;

  /// 覆蓋既有筆數（PM 2026-11-19：重複處理＝覆蓋時 >0）。
  final int overwritten;
  final int categoriesCreated;
}
