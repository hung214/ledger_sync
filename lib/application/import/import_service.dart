import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/hlc.dart';
import '../../data/sqlite/app_database.dart';
import 'csv_import_parser.dart';
import 'import_models.dart';

/// AndroMoney 匯入服務（I3.3；tasks §6.0；PM 2026-11-16 決策）。
///
/// - **preview**：解析＋統計（筆數·期間·各類型金額合計·重複·錯誤·非 TWD）＋
  /// 「將自動建立」之帳戶/分類清單——I4「選檔→預覽/乾跑」畫面直接呈現。
/// - **apply**：逐列落地——未知**帳戶/分類自動建立**（PM 決策）；交易＋oplog
  /// 同一 DB transaction（SDD §5.1 契約；payload＝整列快照）；**去重鍵命中即跳過**
  /// （日期＋金額＋備註＋帳戶；PM 2026-11-16 決策）→ **重複匯入冪等**。
/// - **幣別**：僅接受 TWD（多幣別語意未定＝略過並標示，SP-x）。
/// - 安全（I5）：匯入前備份與可回溯由呼叫端（I4 入口）接 `BackupService`——
  /// oplog 墓標契約即為可回溯基礎。
class ImportService {
  ImportService(this._db, {this.deviceId = 'import'});

  final AppDatabase _db;
  final String deviceId;

  static const String defaultCurrency = CsvImportParser.defaultCurrency;

  /// 解析＋預覽（不寫 DB）。
  ImportPreview preview(String csv) {
    final parsed = CsvImportParser.parse(csv);

    // 既有帳戶/分類（正規化名稱比對；含 archived——同名即沿用其 id）。
    final accountByName = <String, AccountRow>{};
    for (final a in _db.allAccounts()) {
      accountByName[_norm(a.name)] = a;
    }
    final categoryIds = <String, CategoryRow>{};
    for (final kind in ['expense', 'income']) {
      for (final c in _db.categoriesByKind(kind)) {
        if (c.deletedAt == null) categoryIds['${c.kind}/${_norm(c.name)}'] = c;
      }
    }

    // 去重：對 DB（已有帳戶者）＋檔內（DedupKey 集合）。
    final duplicateLines = <int>[];
    final seenInFile = <String>{};
    final importable = <ImportRow>[];
    for (final row in parsed.rows) {
      if (seenInFile.contains(row.dedupKey)) {
        duplicateLines.add(row.lineNo);
        continue;
      }
      seenInFile.add(row.dedupKey);
      if (_existsInDb(row, accountByName)) {
        duplicateLines.add(row.lineNo);
        continue;
      }
      importable.add(row);
    }

    final totals = <ImportKind, int>{
      for (final k in ImportKind.values)
        k: importable.where((r) => r.kind == k).fold(0, (s, r) => s + r.amountMinor),
    };
    final dates = importable.map((r) => r.date).toList();

    final newAccounts = <String>{};
    final newMain = <String, Set<String>>{
      'expense': <String>{},
      'income': <String>{},
    };
    final newSub = <String, Set<String>>{};
    for (final r in importable) {
      if (!accountByName.containsKey(_norm(r.account))) newAccounts.add(r.account);
      if (r.kind == ImportKind.transfer || r.category == null) continue;
      final kind = r.kind == ImportKind.expense ? 'expense' : 'income';
      final mainKey = '$kind/${_norm(r.category!)}';
      if (!categoryIds.containsKey(mainKey)) newMain[kind]!.add(r.category!);
      if (r.subcategory != null) {
        final mainExists = categoryIds.containsKey(mainKey) ||
            newMain[kind]!.contains(r.category);
        final subExists = categoryIds.containsKey('$kind/${_norm(r.subcategory!)}');
        if (mainExists && !subExists) {
          newSub.putIfAbsent(r.category!, () => <String>{}).add(r.subcategory!);
        }
      }
    }

    return ImportPreview(
      rows: importable,
      errors: parsed.errors,
      skippedCurrency: parsed.skippedCurrency,
      duplicateLines: duplicateLines,
      totalsMinor: totals,
      minDate: dates.isEmpty ? null : dates.reduce((a, b) => a.isBefore(b) ? a : b),
      maxDate: dates.isEmpty ? null : dates.reduce((a, b) => a.isAfter(b) ? a : b),
      newAccounts: newAccounts,
      newMainCategories: newMain,
      newSubCategories: newSub,
    );
  }

  /// 落地（**重複匯入冪等**——preview() 對當下 DB 重新去重，重跑同檔＝全數命中、0 新增）。
  ImportReport apply(String csv) {
    final stats = preview(csv);

    // 自動建立帳戶（PM 決策：未知→自動；型別＝現金、計入合併統計；含 archived 同名沿用）。
    final accountIds = <String, String>{};
    for (final a in _db.allAccounts()) {
      accountIds[_norm(a.name)] = a.id;
    }
    var accountsCreated = 0;
    void ensureAccount(String name) {
      final key = _norm(name);
      if (accountIds.containsKey(key)) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final hlc = Hlc.now(deviceId).toString();
      final row = AccountRow(
        id: const Uuid().v7(),
        type: 'cash',
        name: name,
        currency: defaultCurrency,
        openingAmountMinor: 0,
        archived: false,
        createdAt: now,
        updatedAt: now,
        hlc: hlc,
      );
      _db.insertAccountWithOplog(
        row,
        OplogRow(
          entity: 'accounts',
          entityId: row.id,
          hlc: hlc,
          payload: jsonEncode(row.toSnapshot()),
          packedSeq: null,
        ),
      );
      accountIds[key] = row.id;
      accountsCreated++;
    }

    // 自動建立分類（主／子；kind 由交易類型決定；同 kind 同名即用）。
    final categoryIds = <String, String>{};
    for (final kind in ['expense', 'income']) {
      for (final c in _db.categoriesByKind(kind)) {
        if (c.deletedAt == null) categoryIds['${c.kind}/${_norm(c.name)}'] = c.id;
      }
    }
    var categoriesCreated = 0;
    String? ensureCategory(String kind, String name, {String? parentName}) {
      final key = '$kind/${_norm(name)}';
      if (categoryIds.containsKey(key)) return categoryIds[key];
      String? parentId;
      if (parentName != null) {
        final pKey = '$kind/${_norm(parentName)}';
        parentId = categoryIds[pKey];
        if (parentId == null) return null; // 主分類未建立（不應發生；防禦）
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final hlc = Hlc.now(deviceId).toString();
      final row = CategoryRow(
        id: const Uuid().v7(),
        kind: kind,
        parentId: parentId,
        name: name,
        isSystem: false,
        createdAt: now,
        updatedAt: now,
        hlc: hlc,
      );
      _db.insertCategoryWithOplog(
        row,
        OplogRow(
          entity: 'categories',
          entityId: row.id,
          hlc: hlc,
          payload: jsonEncode(row.toSnapshot()),
          packedSeq: null,
        ),
      );
      categoryIds[key] = row.id;
      categoriesCreated++;
      return row.id;
    }

    // 落地列＝stats.rows（已去重：檔內＋對當下 DB——冪等保證）。
    var inserted = 0;
    var transfers = 0;

    for (final row in stats.rows) {
      ensureAccount(row.account);
      String? toAccountId;
      if (row.kind == ImportKind.transfer && row.toAccount != null) {
        ensureAccount(row.toAccount!);
        toAccountId = accountIds[_norm(row.toAccount!)];
      }
      String? categoryId;
      if (row.kind != ImportKind.transfer && row.category != null) {
        final kind = row.kind == ImportKind.expense ? 'expense' : 'income';
        ensureCategory(kind, row.category!);
        categoryId = ensureCategory(
          kind,
          row.subcategory ?? row.category!,
          parentName: row.subcategory == null ? null : row.category,
        );
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final hlc = Hlc.now(deviceId).toString();
      final tx = TxRow(
        id: const Uuid().v7(),
        kind: row.kind.name,
        amountMinor: row.amountMinor,
        currency: row.currency,
        accountId: accountIds[_norm(row.account)]!,
        toAccountId: toAccountId,
        categoryId: categoryId,
        merchant: row.merchant,
        note: row.note,
        occurredAt: row.date.millisecondsSinceEpoch,
        source: 'import',
        settlementStatus: 'none',
        createdAt: now,
        updatedAt: now,
        hlc: hlc,
      );
      _db.saveTransactionWithOplog(
        tx,
        OplogRow(
          entity: 'transactions',
          entityId: tx.id,
          hlc: tx.hlc,
          payload: jsonEncode(tx.toSnapshot()),
          packedSeq: null,
        ),
      );
      inserted++;
      if (row.kind == ImportKind.transfer) transfers++;
    }

    return ImportReport(
      inserted: inserted,
      transfersInserted: transfers,
      skippedDuplicate: stats.duplicateLines.length,
      errorRows: stats.errors.length,
      skippedCurrencyRows: stats.skippedCurrency.length,
      accountsCreated: accountsCreated,
      categoriesCreated: categoriesCreated,
    );
  }

  /// 去重（PM 2026-11-16 決策：日期＋金額＋備註＋帳戶）——查既有 DB。
  ///
  /// [accountByName]＝正規化名稱→帳戶列（未知帳戶不可能已在 DB，直接 false）。
  bool _existsInDb(ImportRow row, Map<String, AccountRow> accountByName) {
    final accountId = accountByName[_norm(row.account)]?.id;
    if (accountId == null) return false;
    final dayStart = DateTime(row.date.year, row.date.month, row.date.day)
        .millisecondsSinceEpoch;
    final rows = _db.select(
      'SELECT id FROM transactions '
      'WHERE occurred_at = ? AND amount_minor = ? AND account_id = ? '
      "AND (note = ? OR (note IS NULL AND ? = '')) "
      'AND deleted_at IS NULL LIMIT 1',
      [
        dayStart,
        row.amountMinor,
        accountId,
        row.note ?? '',
        row.note ?? '',
      ],
    );
    return rows.isNotEmpty;
  }

  static String _norm(String s) => s.trim().toLowerCase();
}
