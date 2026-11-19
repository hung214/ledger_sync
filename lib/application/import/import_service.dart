import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/clock.dart';
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
      if (_findExistingId(row, accountByName) != null) {
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

  /// 落地（**重複匯入冪等**——同檔重跑＝全數命中、0 新增）。
  ///
  /// [overwriteDuplicates]（PM 2026-11-19：重複處理「略過（預設）／覆蓋」二選一）：
  /// true → 對 DB 命中之重複列**以匯入資料覆蓋**（金額/分類/商家/備註/日期）；
  /// false（預設）→ 略過。
  ImportReport apply(String csv, {bool overwriteDuplicates = false}) {
    final parsed = CsvImportParser.parse(csv);

    // 既有帳戶（名稱→列；去重比對用——同 preview()）。
    final accountByName = <String, AccountRow>{};
    for (final a in _db.allAccounts()) {
      accountByName[_norm(a.name)] = a;
    }

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

    // 落地（**含重複判斷**——檔內＋對當下 DB；冪等保證）。
    var inserted = 0;
    var transfers = 0;
    var overwritten = 0;
    var skippedDuplicate = 0;
    final seenInFile = <String>{};
    final insertedIds = <String>[];

    for (final row in parsed.rows) {
      if (seenInFile.contains(row.dedupKey)) {
        skippedDuplicate++; // 檔內重複（同一列無獨立既有對象）
        continue;
      }
      seenInFile.add(row.dedupKey);
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
      final existingId = _findExistingId(row, accountByName);
      if (existingId != null) {
        if (!overwriteDuplicates) {
          skippedDuplicate++; // 對 DB 重複（預設：略過）
          continue;
        }
        _overwriteExisting(existingId, row,
            accountId: accountIds[_norm(row.account)]!,
            toAccountId: toAccountId,
            categoryId: categoryId);
        overwritten++;
        continue;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final hlc = Hlc.now(deviceId).toString();
      // PM 2026-11-19 修復：匯入到信用卡帳戶的支出/退款＝預扣（pending）——
      // 否則「應付」恆 0（與快記存檔同一口徑）。
      final isCreditAccount = accountByName[_norm(row.account)]?.type == 'credit';
      final settlementStatus = isCreditAccount &&
              (row.kind == ImportKind.expense)
          ? 'pending'
          : 'none';
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
        settlementStatus: settlementStatus,
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
      insertedIds.add(tx.id);
      if (row.kind == ImportKind.transfer) transfers++;
    }
    if (insertedIds.isNotEmpty) recordBatch(insertedIds); // I5：可回溯

    return ImportReport(
      inserted: inserted,
      transfersInserted: transfers,
      skippedDuplicate: skippedDuplicate,
      errorRows: parsed.errors.length,
      skippedCurrencyRows: parsed.skippedCurrency.length,
      accountsCreated: accountsCreated,
      categoriesCreated: categoriesCreated,
      overwritten: overwritten,
    );
  }

  /// 去重（PM 2026-11-16 決策：日期＋金額＋備註＋帳戶）——查既有 DB。
  ///
  /// **當日範圍**比對（PM 2026-11-19 修復：原用 `occurred_at = 當日零點`，
  /// 而交易存**含時間**戳 → 同日重匯永遠對不上＝重複灌入）。
  /// 回傳命中之既有交易 id（供覆蓋模式更新）；null＝無重複。
  /// [accountByName]＝正規化名稱→帳戶列（未知帳戶不可能已在 DB，回 null）。
  String? _findExistingId(ImportRow row, Map<String, AccountRow> accountByName) {
    final accountId = accountByName[_norm(row.account)]?.id;
    if (accountId == null) return null;
    final dayStart = DateTime(row.date.year, row.date.month, row.date.day)
        .millisecondsSinceEpoch;
    final dayEnd = DateTime(row.date.year, row.date.month, row.date.day + 1)
        .millisecondsSinceEpoch;
    final rows = _db.select(
      'SELECT id FROM transactions '
      'WHERE occurred_at >= ? AND occurred_at < ? '
      'AND amount_minor = ? AND account_id = ? '
      "AND (note = ? OR (note IS NULL AND ? = '')) "
      'AND deleted_at IS NULL LIMIT 1',
      [
        dayStart,
        dayEnd,
        row.amountMinor,
        accountId,
        row.note ?? '',
        row.note ?? '',
      ],
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  /// 覆蓋既有交易（PM 2026-11-19「重複處理＝覆蓋」）：以匯入列更新
  /// 金額/類型/帳戶/分類/商家/備註/日期；保留 id/附件/建立時間＋oplog（同步）。
  void _overwriteExisting(String id, ImportRow row,
      {required String accountId, String? toAccountId, String? categoryId}) {
    final existing = _db.transactionById(id);
    if (existing == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final hlc = Hlc.now(deviceId).toString();
    final tx = TxRow(
      id: existing.id,
      kind: row.kind.name,
      amountMinor: row.amountMinor,
      currency: row.currency,
      accountId: accountId,
      toAccountId: toAccountId,
      categoryId: categoryId,
      merchant: row.merchant,
      note: row.note,
      occurredAt: row.date.millisecondsSinceEpoch,
      source: existing.source,
      settlementStatus: existing.settlementStatus,
      splitGroupId: existing.splitGroupId,
      installmentSeq: existing.installmentSeq,
      createdAt: existing.createdAt,
      updatedAt: now,
      hlc: hlc,
      deletedAt: existing.deletedAt,
    );
    _db.updateTransactionWithOplog(
      tx,
      OplogRow(
        entity: 'transactions',
        entityId: tx.id,
        hlc: hlc,
        payload: jsonEncode(tx.toSnapshot()),
        packedSeq: null,
      ),
    );
  }

  static String _norm(String s) => s.trim().toLowerCase();

  // ── I5：批次可回溯（settings 記錄批次 id；取消＝軟刪除＋墓標 oplog——同步安全）──

  static const String _batchKey = 'import.batch.last';

  /// 記錄最近一批匯入的交易 id（apply 後由 UI 呼叫）。
  void recordBatch(List<String> ids) {
    _db.setSetting(
        _batchKey,
        jsonEncode({
          'ids': ids,
          'at': Clock.now().millisecondsSinceEpoch,
        }));
  }

  /// 是否有可取消之批次。
  bool get hasUndoableBatch {
    final raw = _db.getSetting(_batchKey);
    if (raw == null) return false;
    final ids = ((jsonDecode(raw) as Map<String, Object?>)['ids'] as List?) ?? const [];
    return ids.isNotEmpty;
  }

  /// **取消本批匯入**：軟刪除該批全部交易＋oplog 墓標（NULL payload；
  /// SDD §5.5.4——其他裝置 pull 後同步刪除）。回傳取消筆數（冪等：重複呼叫 0）。
  int undoLastBatch() {
    final raw = _db.getSetting(_batchKey);
    if (raw == null) return 0;
    final ids =
        ((jsonDecode(raw) as Map<String, Object?>)['ids'] as List?)?.cast<String>() ??
            const [];
    if (ids.isEmpty) return 0;
    final now = Clock.now().millisecondsSinceEpoch;
    var n = 0;
    for (final id in ids) {
      final h = Hlc.now(deviceId).toString();
      _db.softDeleteTransactionWithOplog(
        id,
        OplogRow(
            entity: 'transactions',
            entityId: id,
            hlc: h,
            payload: null, // 墓標
            packedSeq: null),
        deletedAt: now,
        hlc: h,
      );
      n++;
    }
    _db.setSetting(_batchKey, jsonEncode({'ids': <String>[], 'undone': true}));
    return n;
  }
}
