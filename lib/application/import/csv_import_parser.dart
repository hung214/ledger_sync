import 'dart:convert';

import 'package:intl/intl.dart';

import 'import_models.dart';

/// AndroMoney CSV 解析器（I3.2；**純函式**——不觸 DB）。
///
/// - **分隔符自動偵測**：表頭列統計 `,`／`;`／`\t` 取最多（預設 `,`）；BOM 剝除。
/// - **表頭別名對映**（大小寫不敏感；中／英並列）——真實檔案到位後（I1/I2）
///   僅需擴充本表。
/// - **日期**多格式（見 [_datePatterns]；4 位年開頭優先；`M/d` vs `d/M` 歧義
///   以 `M/d` 解——日＞12 時自然消歧；I2 可再依真檔調整順序）。
/// - **金額**：剝貨幣符號／空白；千分位（`,`／`.`／空白）與小數點以**最右者為
///   小數**消歧；`(123)`／前導 `-`＝負；回傳**正數** minor（方向由 Type 欄）。
/// - **Type**：支出/expense／收入/income／轉帳/transfer（大小寫不敏感）；
///   空白時以金額正負推定（負→支出）。
/// - **幣別**：欄位缺漏→預設 `TWD`；非 TWD 列→[ImportPreview.skippedCurrency]
///   （多幣別語意未定＝略過並標示，SP-x）。
class CsvImportParser {
  CsvImportParser._();

  static const String defaultCurrency = 'TWD';

  static const List<String> _datePatterns = [
    'yyyy-MM-dd',
    'yyyy/M/d',
    'yyyy/MM/dd',
    'yyyy年M月d日',
    'M/d/yyyy',
    'MM/dd/yyyy',
    'dd/MM/yyyy',
    'yyyyMMdd',
  ];

  static const Map<String, List<String>> _aliases = {
    'date': ['date', '日期', '日付'],
    'type': ['type', '交易類型', '類型', '類別類型'],
    'amount': ['amount', '金額'],
    'currency': ['currency', '幣別', '貨幣'],
    'account': ['account', '帳戶', '帳號'],
    'toAccount': ['to account', 'transfer account', '轉入帳戶', '轉出至', '目標帳戶'],
    'category': ['category', '分類', '類別'],
    'subcategory': ['subcategory', 'sub category', '子分類', '子類別'],
    'merchant': ['payee', 'merchant', '商家', '對象'],
    'note': ['note', 'memo', 'remark', '備註', '備注', '註解'],
  };

  /// 解析整份 CSV。
  static CsvParseResult parse(String csv) {
    final lines = _physicalLines(csv);
    if (lines.isEmpty) return const CsvParseResult(rows: [], errors: []);

    final header = _split(_stripBom(lines.first), _detectDelimiter(lines.first));
    final cols = <String, int>{};
    header.asMap().forEach((i, raw) {
      final h = _norm(raw);
      for (final e in _aliases.entries) {
        if (e.value.any((a) => _norm(a) == h)) cols[e.key] = i;
      }
    });
    final fatal = _missingRequired(cols);
    if (fatal != null) {
      return CsvParseResult(rows: const [], errors: [
        ImportError(lineNo: 1, reason: fatal),
      ]);
    }

    final rows = <ImportRow>[];
    final errors = <ImportError>[];
    final skippedCurrency = <ImportRow>[];
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) continue;
      final c = _split(line, _detectDelimiter(lines.first));
      String? cell(String key) {
        final idx = cols[key];
        if (idx == null || idx >= c.length) return null;
        final v = c[idx].trim();
        return v.isEmpty ? null : v;
      }

      final lineNo = i + 1;
      final amountRaw = cell('amount');
      final amountMinor = amountRaw == null ? null : parseAmountMinor(amountRaw);
      if (amountMinor == null) {
        errors.add(ImportError(lineNo: lineNo, reason: '金額無法解析：${amountRaw ?? '（空）'}'));
        continue;
      }
      final dateRaw = cell('date');
      final date = dateRaw == null ? null : parseDate(dateRaw);
      if (date == null) {
        errors.add(ImportError(lineNo: lineNo, reason: '日期無法解析：${dateRaw ?? '（空）'}'));
        continue;
      }
      final account = cell('account');
      if (account == null) {
        errors.add(ImportError(lineNo: lineNo, reason: '帳戶空白'));
        continue;
      }
      final kind = parseKind(cell('type'), amountMinor < 0);
      if (kind == null) {
        errors.add(ImportError(
            lineNo: lineNo, reason: '類型無法辨識：${cell('type')}'));
        continue;
      }
      if (kind == ImportKind.transfer && cell('toAccount') == null) {
        errors.add(ImportError(lineNo: lineNo, reason: '轉帳缺「轉入帳戶」欄'));
        continue;
      }
      final currency = cell('currency') ?? defaultCurrency;
      final row = ImportRow(
        lineNo: lineNo,
        kind: kind,
        date: date,
        amountMinor: amountMinor.abs(),
        currency: currency.toUpperCase(),
        account: account,
        toAccount: cell('toAccount'),
        category: cell('category'),
        subcategory: cell('subcategory'),
        merchant: cell('merchant'),
        note: cell('note'),
      );
      if (row.currency != defaultCurrency) {
        skippedCurrency.add(row); // 多幣別語意未定＝略過（SP-x）
        continue;
      }
      rows.add(row);
    }
    return CsvParseResult(rows: rows, errors: errors, skippedCurrency: skippedCurrency);
  }

  /// 金額字串 → minor（**保留負號**；方向由 Type 欄決定，負號僅供空 Type 推定）。
  static int? parseAmountMinor(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    var neg = false;
    if (s.startsWith('(') && s.endsWith(')')) {
      neg = true;
      s = s.substring(1, s.length - 1);
    }
    s = s.replaceAll(RegExp(r'[^0-9.,\-+]'), '');
    if (s.startsWith('-')) {
      neg = true;
      s = s.substring(1);
    } else if (s.startsWith('+')) {
      s = s.substring(1);
    }
    if (s.isEmpty) return null;
    final lastDot = s.lastIndexOf('.');
    final lastComma = s.lastIndexOf(',');
    if (lastDot >= 0 && lastComma >= 0) {
      // 兩者並存：最右者＝小數點，另一個＝千分位。
      if (lastComma > lastDot) {
        s = s.replaceAll('.', '').replaceAll(',', '.');
      } else {
        s = s.replaceAll(',', '');
      }
    } else if (lastComma >= 0) {
      final frac = s.length - lastComma - 1;
      final groups = RegExp(r'^\d{1,3}(,\d{3})+$').hasMatch(s);
      if (groups && frac == 3) {
        s = s.replaceAll(',', ''); // 1,234 千分位
      } else {
        s = s.replaceAll(',', '.'); // 1234,56 歐式小數
      }
    } else if (lastDot >= 0 && RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(s)) {
      // 僅點：1.234（三碼一組）視為千分位（歐式）；1.2/1.23 視為小數。
      s = s.replaceAll('.', '');
    }
    final value = double.tryParse(s);
    if (value == null) return null;
    final minor = (value * 100).round();
    return neg ? -minor : minor;
  }

  /// 日期解析（[_datePatterns] 順序；全部失敗回 null）。
  static DateTime? parseDate(String raw) {
    final s = raw.trim();
    // 緊湊 8 位（yyyyMMdd；intl parseLoose 不支援無分隔格式）。
    final compact = RegExp(r'^(\d{4})(\d{2})(\d{2})$').firstMatch(s);
    if (compact != null) {
      final y = int.parse(compact.group(1)!);
      final m = int.parse(compact.group(2)!);
      final d = int.parse(compact.group(3)!);
      if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        return DateTime(y, m, d);
      }
    }
    for (final p in _datePatterns) {
      try {
        return DateFormat(p).parseLoose(s);
      } on FormatException {
        // 試下一格式
      }
    }
    return null;
  }

  /// Type 欄 → [ImportKind]；空白時以金額正負推定；不認得回 null。
  static ImportKind? parseKind(String? raw, bool amountNegative) {
    final t = (raw ?? '').trim().toLowerCase();
    if (t.isEmpty) {
      return amountNegative ? ImportKind.expense : ImportKind.income;
    }
    if (t.contains('支出') || t.contains('expense') || t == 'out') {
      return ImportKind.expense;
    }
    if (t.contains('收入') || t.contains('income') || t == 'in') {
      return ImportKind.income;
    }
    if (t.contains('轉') || t.contains('transfer')) return ImportKind.transfer;
    return null;
  }

  static String _stripBom(String s) =>
      s.startsWith('\uFEFF') ? s.substring(1) : s;

  static List<String> _physicalLines(String csv) => LineSplitter.split(csv).toList();

  static String _detectDelimiter(String headerLine) {
    var best = ',';
    var bestCount = 0;
    for (final d in [',', ';', '\t']) {
      final n = d.allMatches(headerLine).length;
      if (n > bestCount) {
        best = d;
        bestCount = n;
      }
    }
    return best;
  }

  static String _norm(String s) => s.trim().toLowerCase().replaceAll(' ', '');

  /// CSV 單列切分（支援雙引號欄位；`""`＝跳脫引號）。
  static List<String> _split(String line, String delim) {
    final out = <String>[];
    final buf = StringBuffer();
    var inQuote = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        if (inQuote && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuote = !inQuote;
        }
      } else if (!inQuote && c == delim) {
        out.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    out.add(buf.toString());
    return out;
  }

  /// 必要欄位檢查（date/amount/account）——缺任一＝整份無法解析。
  static String? _missingRequired(Map<String, int> cols) {
    const requiredKeys = ['date', 'amount', 'account'];
    final missing =
        requiredKeys.where((k) => !cols.containsKey(k)).toList(growable: false);
    if (missing.isEmpty) return null;
    final zh = {
      'date': '日期',
      'amount': '金額',
      'account': '帳戶',
    };
    return '表頭缺少必要欄位：${missing.map((m) => '$m（${zh[m]}）').join('、')}';
  }
}

/// 解析結果（rows＝可匯入；errors＝壞列；skippedCurrency＝非 TWD 略過列）。
class CsvParseResult {
  const CsvParseResult({
    required this.rows,
    required this.errors,
    this.skippedCurrency = const [],
  });

  final List<ImportRow> rows;
  final List<ImportError> errors;
  final List<ImportRow> skippedCurrency;
}
