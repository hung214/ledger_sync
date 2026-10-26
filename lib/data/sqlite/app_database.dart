import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../core/clock.dart';
import '../../core/text_index.dart';
import 'schema.dart';

/// Windows 測試環境：系統內建 winsqlite3.dll（App 執行時由 sqlite3_flutter_libs
/// 提供 bundled sqlite3）。須在任何開庫動作前呼叫一次。
void ensureSqliteOpenable() {
  if (Platform.isWindows) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
}

/// App 資料庫（Schema v1 = M1 核心記帳，逐句對齊 specs/truth/data-spec.dbml）。
///
/// T-S1 過渡實作：sqlite3 直連（drift 暫緩，research TR-7——工具鏈與 Dart 3.13.5
/// 相容問題，M1 前於 CI 重試回歸 drift；屆時本層 API 維持不變，僅換底層）。
class AppDatabase {
  AppDatabase.inMemory() {
    ensureSqliteOpenable();
    _db = sqlite3.openInMemory();
    _migrate();
  }

  AppDatabase.open(String path) {
    ensureSqliteOpenable();
    _db = sqlite3.open(path, mode: OpenMode.readWriteCreate);
    _migrate();
  }

  late final Database _db;
  bool _closed = false;

  int get schemaVersion => SchemaV6.version;

  void _migrate() {
    // DBG-004／T-S2：多版本冪等遷移——
    // ① `PRAGMA user_version` 版本閘：已達最新直接跳過（第二啟動不再重跑 DDL）。
    // ② 既有表偵測：v0.4.x 期間建立、user_version 未標記之舊檔 → 補標 v1。
    // ③ 逐版本增量：每版本於交易內全有全無（v1 全量 DDL／v2 增量表）。
    // DDL 字串維持原樣（T-H9 truth 對齊 regex 相容）。
    var current = _db.select('PRAGMA user_version').first.values.first as int;
    if (current >= SchemaV6.version) return;
    if (current < 1) {
      final tablesExist = _db
          .select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'accounts'")
          .isNotEmpty;
      if (tablesExist) {
        current = 1;
        _db.execute('PRAGMA user_version = ${SchemaV1.version}');
      }
    }
    if (current < 1) {
      _db.execute('BEGIN');
      try {
        for (final s in SchemaV1.statements) {
          _db.execute(s);
        }
        for (final s in SchemaV1.indexes) {
          _db.execute(s);
        }
        _db.execute('PRAGMA user_version = ${SchemaV1.version}');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }
    if (current < 2) {
      _db.execute('BEGIN');
      try {
        for (final s in SchemaV2.statements) {
          _db.execute(s);
        }
        _db.execute('PRAGMA user_version = ${SchemaV2.version}');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
      // FTS5 虛擬表：環境缺模組時**容錯降級**（不阻斷 v2；F10 依表存在性分流）。
      for (final s in SchemaV2.ftsStatements) {
        try {
          _db.execute(s);
        } catch (e) {
          // ignore: avoid_print
          print('T-S2：FTS5 建表跳過（環境不支援）——$e');
        }
      }
    }
    if (current < 3) {
      _db.execute('BEGIN');
      try {
        for (final s in SchemaV3.statements) {
          _db.execute(s);
        }
        _db.execute('PRAGMA user_version = ${SchemaV3.version}');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }
    if (current < 4) {
      _db.execute('BEGIN');
      try {
        for (final s in SchemaV4.statements) {
          _db.execute(s);
        }
        _db.execute('PRAGMA user_version = ${SchemaV4.version}');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }
    if (current < 5) {
      _db.execute('BEGIN');
      try {
        for (final s in SchemaV5.statements) {
          _db.execute(s);
        }
        _db.execute('PRAGMA user_version = ${SchemaV5.version}');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }
    if (current < 6) {
      // v6（M8）：accounts.include_in_totals（FR-A2/A6/A7 合併計算）。
      _db.execute('BEGIN');
      try {
        for (final s in SchemaV6.statements) {
          _db.execute(s);
        }
        _db.execute('PRAGMA user_version = ${SchemaV6.version}');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }
  }

  List<String> tableNames() => _db
      .select("SELECT name FROM sqlite_master WHERE type='table'")
      .map((r) => r['name'] as String)
      .toList();

  /// 唯讀查詢代理（BackupService 快照等服務用；寫入仍走具名方法）。
  List<Map<String, Object?>> select(String sql, [List<Object?> args = const []]) =>
      [for (final r in _db.select(sql, args)) Map<String, Object?>.from(r)];

  /// SQL 執行代理（fixture/服務輔助；業務寫入仍走具名方法以保證 oplog 契約）。
  void execute(String sql, [List<Object?> args = const []]) => _db.execute(sql, args);

  void close() {
    if (!_closed) {
      _db.dispose();
      _closed = true;
    }
  }

  // ── 帳戶（FR-A） ──────────────────────────────────────────

  void insertAccount(AccountRow a) => _db.execute(
        'INSERT INTO accounts (id, type, name, currency, opening_amount_minor, include_in_totals, archived, created_at, updated_at, hlc)'
        ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          a.id, a.type, a.name, a.currency, a.openingAmountMinor,
          a.includeInTotals ? 1 : 0, a.archived ? 1 : 0, a.createdAt,
          a.updatedAt, a.hlc,
        ],
      );

  /// 帳戶更新（整列覆寫；FR-A7 編輯）——呼叫端負責同 transaction 之 oplog。
  void updateAccount(AccountRow a) => _db.execute(
        'UPDATE accounts SET type = ?, name = ?, currency = ?, opening_amount_minor = ?,'
        ' include_in_totals = ?, archived = ?, updated_at = ?, hlc = ? WHERE id = ?',
        [
          a.type, a.name, a.currency, a.openingAmountMinor,
          a.includeInTotals ? 1 : 0, a.archived ? 1 : 0, a.updatedAt, a.hlc, a.id,
        ],
      );

  /// 帳戶刪除（實體刪除；FR-A2 需無未結算交易——由 AccountService 把關）。
  void deleteAccount(String id) =>
      _db.execute('DELETE FROM accounts WHERE id = ?', [id]);

  /// 帳戶變更 + oplog 追加於同一 transaction（SDD §5.1 契約；F11 FR-A7）。
  void mutateAccountWithOplog(AccountRow a, OplogRow o, {required bool delete}) {
    _db.execute('BEGIN');
    try {
      if (delete) {
        deleteAccount(a.id);
      } else {
        updateAccount(a);
      }
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 帳戶寫入 + oplog 追加於同一 transaction（SDD §5.1 契約；首次啟動播種用）。
  void insertAccountWithOplog(AccountRow a, OplogRow o) {
    _db.execute('BEGIN');
    try {
      insertAccount(a);
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<AccountRow> allAccounts() => _db
      .select('SELECT * FROM accounts ORDER BY sort_order IS NULL, sort_order')
      .map(AccountRow.fromRow)
      .toList();

  // ── 分類（FR-B1） ─────────────────────────────────────────

  void insertCategory(CategoryRow c) => _db.execute(
        'INSERT INTO categories (id, kind, parent_id, name, icon, color, sort_order, is_system, created_at, updated_at, hlc, deleted_at)'
        ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          c.id, c.kind, c.parentId, c.name, c.icon, c.color, c.sortOrder,
          c.isSystem ? 1 : 0, c.createdAt, c.updatedAt, c.hlc, c.deletedAt,
        ],
      );

  /// 分類更新（整列覆寫；FR-B1 編輯/排序/封存）——呼叫端負責同 transaction
  /// 之 oplog。
  void updateCategory(CategoryRow c) => _db.execute(
        'UPDATE categories SET name = ?, icon = ?, color = ?, sort_order = ?,'
        ' is_system = ?, updated_at = ?, hlc = ?, deleted_at = ? WHERE id = ?',
        [
          c.name, c.icon, c.color, c.sortOrder, c.isSystem ? 1 : 0,
          c.updatedAt, c.hlc, c.deletedAt, c.id,
        ],
      );

  /// 分類刪除（實體；FR-B1 有交易引用→由 CategoryService 拒絕）。
  void deleteCategory(String id) =>
      _db.execute('DELETE FROM categories WHERE id = ?', [id]);

  /// 分類變更 + oplog 追加於同一 transaction（SDD §5.1 契約；F11 FR-B1）。
  void mutateCategoryWithOplog(CategoryRow c, OplogRow o,
      {required bool delete}) {
    _db.execute('BEGIN');
    try {
      if (delete) {
        deleteCategory(c.id);
      } else {
        updateCategory(c);
      }
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 分類排序批次寫入 + 各自 oplog（同一 transaction；FR-B1 reorder）。
  void reorderCategoriesWithOplog(List<(CategoryRow, OplogRow)> items) {
    _db.execute('BEGIN');
    try {
      for (final (c, o) in items) {
        updateCategory(c);
        appendOp(o);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 分類寫入 + oplog 追加於同一 transaction（SDD §5.1 契約；首次啟動播種用）。
  void insertCategoryWithOplog(CategoryRow c, OplogRow o) {
    _db.execute('BEGIN');
    try {
      insertCategory(c);
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<CategoryRow> categoriesByKind(String kind) => _db
      .select('SELECT * FROM categories WHERE kind = ? ORDER BY sort_order IS NULL, sort_order', [kind])
      .map(CategoryRow.fromRow)
      .toList();

  /// 分類名稱（警示文案用；不存在回 null）。
  String? categoryName(String id) {
    final rows = _db.select('SELECT name FROM categories WHERE id = ?', [id]);
    return rows.isEmpty ? null : rows.first['name'] as String;
  }

  /// 單一分類（PM 2026-10-26：主類別彙總需查 `parent_id`；不存在回 null）。
  CategoryRow? categoryById(String id) {
    final rows = _db.select('SELECT * FROM categories WHERE id = ?', [id]);
    return rows.isEmpty ? null : CategoryRow.fromRow(rows.first);
  }

  // ── 預算／收入目標（FR-B，schema v2；budgets/income_goals 屬 sync_entity） ──

  void insertBudget(BudgetRow b) => _db.execute(
        'INSERT INTO budgets (id, category_id, amount_minor, period_start_day, rollover,'
        ' created_at, updated_at, hlc) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          b.id, b.categoryId, b.amountMinor, b.periodStartDay,
          b.rollover ? 1 : 0, b.createdAt, b.updatedAt, b.hlc,
        ],
      );

  /// 預算寫入 + oplog 追加於同一 transaction（SDD §5.1 契約）。
  void insertBudgetWithOplog(BudgetRow b, OplogRow o) {
    _db.execute('BEGIN');
    try {
      insertBudget(b);
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 預算更新（同 transaction 寫 oplog；UI 編輯用——LWW 整列快照）。
  void updateBudgetWithOplog(BudgetRow b, OplogRow o) {
    _db.execute('BEGIN');
    try {
      _db.execute(
        'UPDATE budgets SET category_id = ?, amount_minor = ?, period_start_day = ?,'
        ' updated_at = ?, hlc = ?, deleted_at = NULL WHERE id = ?',
        [b.categoryId, b.amountMinor, b.periodStartDay, b.updatedAt, b.hlc, b.id],
      );
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 預算軟刪除（deleted_at 標記＋oplog；多裝置合併語意與 categories/accounts 一致）。
  void softDeleteBudgetWithOplog(String id, int deletedAtMs, OplogRow o) {
    _db.execute('BEGIN');
    try {
      _db.execute(
        'UPDATE budgets SET deleted_at = ?, updated_at = ? WHERE id = ?',
        [deletedAtMs, deletedAtMs, id],
      );
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 同 scope（分類／總額）預算之實體清除（fixture 重設語意用；UI 刪除走軟刪除）。
  void deleteBudgetsByCategory(String? categoryId) => _db.execute(
        categoryId == null
            ? 'DELETE FROM budgets WHERE category_id IS NULL'
            : 'DELETE FROM budgets WHERE category_id = ?',
        [?categoryId],
      );

  List<BudgetRow> allBudgets() => _db
      .select('SELECT * FROM budgets WHERE deleted_at IS NULL ORDER BY created_at, id')
      .map(BudgetRow.fromRow)
      .toList();

  void insertIncomeGoal(IncomeGoalRow g) => _db.execute(
        'INSERT INTO income_goals (id, amount_minor, period_start_day, created_at, updated_at, hlc)'
        ' VALUES (?, ?, ?, ?, ?, ?)',
        [g.id, g.amountMinor, g.periodStartDay, g.createdAt, g.updatedAt, g.hlc],
      );

  /// 收入目標寫入 + oplog 追加於同一 transaction（SDD §5.1 契約）。
  void insertIncomeGoalWithOplog(IncomeGoalRow g, OplogRow o) {
    _db.execute('BEGIN');
    try {
      insertIncomeGoal(g);
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 單一目標模型（dbml v0.3）：實體清除舊目標後寫入（fixture 重設語意用）。
  void replaceIncomeGoal(IncomeGoalRow g, OplogRow o) {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM income_goals');
      insertIncomeGoal(g);
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  IncomeGoalRow? activeIncomeGoal() {
    final rows = _db
        .select('SELECT * FROM income_goals WHERE deleted_at IS NULL ORDER BY created_at DESC, id DESC LIMIT 1')
        .map(IncomeGoalRow.fromRow)
        .toList();
    return rows.isEmpty ? null : rows.first;
  }

  // ── 交易（FR-T） ──────────────────────────────────────────

  void insertTransaction(TxRow t) => _db.execute(
        'INSERT INTO transactions (id, kind, amount_minor, currency, fx_rate, account_id,'
        ' to_account_id, category_id, merchant, note, occurred_at, source, split_group_id,'
        ' installment_seq, settlement_status, created_at, updated_at, hlc)'
        ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          t.id, t.kind, t.amountMinor, t.currency, t.fxRate, t.accountId, t.toAccountId,
          t.categoryId, t.merchant, t.note, t.occurredAt, t.source, t.splitGroupId,
          t.installmentSeq, t.settlementStatus, t.createdAt, t.updatedAt, t.hlc,
        ],
      );

  List<TxRow> transactionsByAccount(String accountId) => _db
      .select('SELECT * FROM transactions WHERE account_id = ? ORDER BY occurred_at', [accountId])
      .map(TxRow.fromRow)
      .toList();

  List<TxRow> allTransactions() => _db
      .select('SELECT * FROM transactions ORDER BY occurred_at, id')
      .map(TxRow.fromRow)
      .toList();

  /// 區間內未刪除交易（occurred_at ∈ [start, end)）；本月統計用（F02 S2.3）。
  List<TxRow> transactionsBetween(int startMs, int endMs) => _db
      .select('SELECT * FROM transactions'
              ' WHERE occurred_at >= ? AND occurred_at < ? AND deleted_at IS NULL'
              ' ORDER BY occurred_at, id',
          [startMs, endMs])
      .map(TxRow.fromRow)
      .toList();

  // ── FTS5（FR-R3；schema v2 transactions_fts） ─────────────

  /// FTS5 影子表是否可用（環境缺模組時 false——搜尋降級 LIKE，F10）。
  bool get ftsAvailable => tableNames().contains('transactions_fts');

  /// FTS5 MATCH 查詢 → transactions.rowid 清單；表不可用回 null（呼叫端降級）。
  List<int>? ftsSearch(String matchQuery) {
    if (!ftsAvailable) return null;
    try {
      return _db
          .select('SELECT rowid_ref FROM transactions_fts WHERE transactions_fts MATCH ?',
              [matchQuery])
          .map((r) => r['rowid_ref'] as int)
          .toList();
    } catch (_) {
      return null; // 查詢語法異常等——降級 LIKE
    }
  }

  /// 依 rowid 載入交易（FTS 命中後取列；rowid 為原生索引）。
  List<TxRow> transactionsByRowids(List<int> rowids) {
    if (rowids.isEmpty) return const [];
    final placeholders = List.filled(rowids.length, '?').join(',');
    return _db
        .select('SELECT * FROM transactions WHERE rowid IN ($placeholders)',
            rowids)
        .map(TxRow.fromRow)
        .toList();
  }

  /// 備註更新＋FTS 重索引（測試資料輔助／未來編輯功能之基礎；oplog 由編輯
  /// feature 落地時補齊）。
  void setTransactionNote(String id, String? note) {
    _db.execute('UPDATE transactions SET note = ? WHERE id = ?', [note, id]);
    final row = transactionById(id);
    if (row != null) _ftsReindex(row);
  }

  /// FTS 重索引：以 id 反查 rowid，刪舊插新（冪等）。
  void _ftsReindex(TxRow t) {
    if (!ftsAvailable) return;
    final rowids = _db.select('SELECT rowid FROM transactions WHERE id = ?', [t.id]);
    if (rowids.isEmpty) return;
    final rowid = rowids.first['rowid'] as int;
    _db.execute('DELETE FROM transactions_fts WHERE rowid_ref = ?', [rowid]);
    _db.execute(
      'INSERT INTO transactions_fts (merchant_bigram, note_bigram, rowid_ref) VALUES (?, ?, ?)',
      [TextIndex.bigram(t.merchant), TextIndex.bigram(t.note), rowid],
    );
  }

  /// 備註/商家含關鍵字（FTS5 不可用時之降級路徑；LIKE 樣式由呼叫端帶入）。
  List<TxRow> transactionsContaining(String keyword) {
    final like = '%${keyword.replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
    return _db
        .select(
            "SELECT * FROM transactions WHERE deleted_at IS NULL"
            " AND (note LIKE ? ESCAPE '\\' OR merchant LIKE ? ESCAPE '\\')"
            " ORDER BY occurred_at DESC, id DESC",
            [like, like])
        .map(TxRow.fromRow)
        .toList();
  }

  /// 拆分交易寫入（FR-T6）：N 筆子交易＋N oplog 於**同一 transaction**
  /// （同 split_group_id；FTS 隨寫入維護）——總額守恆由 UseCase 驗證。
  void saveTransactionsSplitWithOplog(List<TxRow> rows, List<OplogRow> ops) {
    assert(rows.length == ops.length);
    _db.execute('BEGIN');
    try {
      for (var i = 0; i < rows.length; i++) {
        insertTransaction(rows[i]);
        _ftsReindex(rows[i]);
        appendOp(ops[i]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 結帳標記：settlement_status → billed（FR-C3；oplog 由結帳批次補——
  /// 與 oplog 同步寫入屬 BillingCycleService 批次契約）。
  void markTransactionBilled(String id, int updatedAtMs, String hlc) {
    _db.execute(
      'UPDATE transactions SET settlement_status = ?, updated_at = ?, hlc = ? WHERE id = ?',
      ['billed', updatedAtMs, hlc, id],
    );
  }

  /// 於單一 DB transaction 內執行 [body]（全有全無；UseCase 複合寫入用，
  /// 如 F04 繳款：repayment 交易＋帳單更新＋各筆 oplog）。
  T runInTransaction<T>(T Function() body) {
    _db.execute('BEGIN');
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 實體刪除交易（FR-C7：分期刪除連動，未到期承諾移除；oplog 保留——
  /// 同步端刪除語意屬 F07 範疇，M3 本地語意為直接移除）。
  /// 不自行包裹 transaction（呼叫端以 runInTransaction 包裹）。
  void deleteTransactionsPhysical(List<String> ids) {
    for (final id in ids) {
      _db.execute('DELETE FROM transactions WHERE id = ?', [id]);
    }
  }

  void insertInstallmentPlan(InstallmentPlanRow p) => _db.execute(
        'INSERT INTO installment_plans (id, account_id, total_minor, installments,'
        ' first_date, note, created_at, updated_at, hlc, deleted_at)'
        ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          p.id, p.accountId, p.totalMinor, p.installments, p.firstDate,
          p.note, p.createdAt, p.updatedAt, p.hlc, p.deletedAt,
        ],
      );

  InstallmentPlanRow? installmentPlanById(String id) {
    final rows = _db
        .select('SELECT * FROM installment_plans WHERE id = ?', [id])
        .map(InstallmentPlanRow.fromRow)
        .toList();
    return rows.isEmpty ? null : rows.first;
  }

  void markInstallmentPlanDeleted(String id, int updatedAtMs, String hlc) {
    _db.execute(
      'UPDATE installment_plans SET deleted_at = ?, updated_at = ?, hlc = ? WHERE id = ?',
      [updatedAtMs, updatedAtMs, hlc, id],
    );
  }

  /// 退款關聯（FR-C8）。
  void insertRefundLink({required String refundTxId, required String originalTxId}) {
    _db.execute(
      'INSERT INTO refund_links (refund_tx_id, original_tx_id) VALUES (?, ?)',
      [refundTxId, originalTxId],
    );
  }

  /// 原交易之退款關聯是否存在（斷言用）。
  bool refundLinkExistsForOriginal(String originalTxId) {
    return _db
        .select('SELECT 1 FROM refund_links WHERE original_tx_id = ?', [originalTxId])
        .isNotEmpty;
  }

  /// 帳單負項沖減（FR-C8）：原交易所屬帳單 total 遞減（M3 簡化——經
  /// statement_items 反查；正式分攤屬 F04 深化）。
  void applyRefundToStatement(
      String originalTxId, int amountMinor, int updatedAtMs, String hlc) {
    final rows = _db.select(
      'SELECT statement_id FROM statement_items WHERE transaction_id = ?',
      [originalTxId],
    );
    if (rows.isEmpty) return; // 未入帳單（pending 退款）→ 無帳單可沖減
    final statementId = rows.first['statement_id'] as String;
    _db.execute(
      'UPDATE statements SET total_minor = total_minor - ?, updated_at = ?, hlc = ?'
      ' WHERE id = ?',
      [amountMinor, updatedAtMs, hlc, statementId],
    );
  }

  /// 批次寫入（單一 transaction；NFR-01 效能測資用，略 oplog/FTS——
  /// 聚合僅讀 transactions。正式寫入路徑仍走 saveTransactionWithOplog）。
  void insertTransactionsBulk(List<TxRow> rows) {
    _db.execute('BEGIN');
    try {
      for (final t in rows) {
        insertTransaction(t);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ── 信用卡明細（FR-A3，schema v3；device-local——不在 sync_entity） ──

  void insertCreditCardDetail(CreditCardDetailRow d) => _db.execute(
        'INSERT INTO credit_card_details (account_id, last4, statement_day, due_offset_days,'
        ' linked_account_id, boundary_rule, credit_limit_minor, effective_from)'
        ' VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          d.accountId, d.last4, d.statementDay, d.dueOffsetDays,
          d.linkedAccountId, d.boundaryRule, d.creditLimitMinor, d.effectiveFrom,
        ],
      );

  /// 帳戶名稱（通知文案用；不存在回 null）。
  String? accountName(String id) {
    final rows = _db.select('SELECT name FROM accounts WHERE id = ?', [id]);
    return rows.isEmpty ? null : rows.first['name'] as String;
  }

  /// 同帳戶同期間之帳單查詢（冪等檢查用）。
  bool statementExistsForPeriod(String accountId, int periodStartMs, int periodEndMs) {
    return _db
        .select(
            'SELECT id FROM statements WHERE account_id = ? AND period_start = ? AND period_end = ?',
            [accountId, periodStartMs, periodEndMs])
        .isNotEmpty;
  }

  /// 修改結帳日（FR-A3：effective_from 下一期生效）。
  void updateCreditCardStatementDay(String accountId, int newDay, int effectiveFromMs) {
    _db.execute(
      'UPDATE credit_card_details SET statement_day = ?, effective_from = ?'
      ' WHERE account_id = ?',
      [newDay, effectiveFromMs, accountId],
    );
  }

  CreditCardDetailRow? creditCardDetail(String accountId) {
    final rows = _db
        .select('SELECT * FROM credit_card_details WHERE account_id = ?', [accountId])
        .map(CreditCardDetailRow.fromRow)
        .toList();
    return rows.isEmpty ? null : rows.first;
  }

  // ── 帳單（FR-C3，schema v3；statements 屬 sync_entity） ────

  void insertStatement(StatementRow s) => _db.execute(
        'INSERT INTO statements (id, account_id, period_start, period_end, statement_date,'
        ' due_date, total_minor, paid_minor, status, paid_at, overdue_notified,'
        ' created_at, updated_at, hlc, deleted_at)'
        ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          s.id, s.accountId, s.periodStart, s.periodEnd, s.statementDate,
          s.dueDate, s.totalMinor, s.paidMinor, s.status, s.paidAt,
          s.overdueNotified ? 1 : 0, s.createdAt, s.updatedAt, s.hlc, s.deletedAt,
        ],
      );

  void insertStatementItems(String statementId, List<String> transactionIds) {
    _db.execute('BEGIN');
    try {
      for (final txId in transactionIds) {
        _db.execute(
          'INSERT OR IGNORE INTO statement_items (statement_id, transaction_id) VALUES (?, ?)',
          [statementId, txId],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 帳單繳款更新（FR-C4；oplog 由 UseCase 於同一 transaction 補）。
  void updateStatementPayment(
      String id, int paidMinor, String status, int? paidAt, int updatedAtMs, String hlc) {
    _db.execute(
      'UPDATE statements SET paid_minor = ?, status = ?, paid_at = ?, updated_at = ?, hlc = ?'
      ' WHERE id = ?',
      [paidMinor, status, paidAt, updatedAtMs, hlc, id],
    );
  }

  /// 帳單查詢（依帳戶＋期間；F04 逾期/提醒用）。
  StatementRow? statementForPeriod(String accountId, int periodStartMs, int periodEndMs) {
    final rows = _db
        .select(
            'SELECT * FROM statements WHERE account_id = ? AND period_start = ? AND period_end = ?',
            [accountId, periodStartMs, periodEndMs])
        .map(StatementRow.fromRow)
        .toList();
    return rows.isEmpty ? null : rows.first;
  }

  /// 全部未刪除帳單（通知檢查巡迴用，F04）。
  List<StatementRow> allStatementsForTest() => _db
      .select('SELECT * FROM statements WHERE deleted_at IS NULL ORDER BY due_date')
      .map(StatementRow.fromRow)
      .toList();

  /// 逾期已通知標記（N-6 恰一次，FR-C6）。
  void markStatementOverdueNotified(String id) {
    _db.execute('UPDATE statements SET overdue_notified = 1 WHERE id = ?', [id]);
  }

  /// 帳單明細之交易 id（歸屬斷言用，F04）。
  List<String> statementItemTxIds(String statementId) {
    return _db
        .select('SELECT transaction_id FROM statement_items WHERE statement_id = ?',
            [statementId])
        .map((r) => r['transaction_id'] as String)
        .toList();
  }

  StatementRow? statementById(String id) {
    final rows =
        _db.select('SELECT * FROM statements WHERE id = ?', [id]).map(StatementRow.fromRow).toList();
    return rows.isEmpty ? null : rows.first;
  }

  // ── 定期交易排程（FR-T5，schema v5；recurring_transactions 屬 sync_entity） ──

  void insertRecurring(RecurringRow r) => _db.execute(
        'INSERT INTO recurring_transactions (id, name, kind, amount_minor, account_id,'
        ' category_id, frequency, interval_days, anchor_date, end_type, end_count,'
        ' end_date, next_due_date, reminder_count, paused, created_at, updated_at,'
        ' hlc, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          r.id, r.name, r.kind, r.amountMinor, r.accountId, r.categoryId,
          r.frequency, r.intervalDays, r.anchorDate, r.endType, r.endCount,
          r.endDate, r.nextDueDate, r.reminderCount, r.paused ? 1 : 0,
          r.createdAt, r.updatedAt, r.hlc, r.deletedAt,
        ],
      );

  /// 排程寫入＋oplog 於同一 transaction（recurring 屬 sync_entity）。
  void insertRecurringWithOplog(RecurringRow r, OplogRow o) {
    _db.execute('BEGIN');
    try {
      insertRecurring(r);
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<RecurringRow> allRecurring() => _db
      .select('SELECT * FROM recurring_transactions WHERE deleted_at IS NULL'
          ' ORDER BY next_due_date')
      .map(RecurringRow.fromRow)
      .toList();

  /// 活躍排程查詢（排除墓標——deleted_at IS NULL；確認/跳過/提醒之對象）。
  RecurringRow? recurringById(String id) {
    final rows = _db.select(
        'SELECT * FROM recurring_transactions WHERE id = ? AND deleted_at IS NULL',
        [id]);
    return rows.isEmpty ? null : RecurringRow.fromRow(rows.first);
  }

  /// 到期未確認佇列（next_due ≤ today；排除暫停/刪除——確認仍可、推播停）。
  List<RecurringRow> dueSchedules(int todayMs) => _db
      .select('SELECT * FROM recurring_transactions'
          ' WHERE deleted_at IS NULL AND paused = 0 AND next_due_date <= ?'
          ' ORDER BY next_due_date', [todayMs])
      .map(RecurringRow.fromRow)
      .toList();

  /// 提醒計數+1；達 3 → paused=true（FR-T5：≥3 停止推播）＋oplog 快照。
  void incrementReminder(String id, String hlc) {
    _db.execute(
      'UPDATE recurring_transactions SET reminder_count = reminder_count + 1,'
      ' paused = CASE WHEN reminder_count + 1 >= 3 THEN 1 ELSE paused END,'
      ' updated_at = ?, hlc = ? WHERE id = ?',
      [Clock.now().millisecondsSinceEpoch, hlc, id],
    );
    appendOp(oplogForRecurring(recurringById(id)!));
  }

  void resetReminder(String id, String hlc) {
    _db.execute(
      'UPDATE recurring_transactions SET reminder_count = 0, paused = 0,'
      ' updated_at = ?, hlc = ? WHERE id = ?',
      [Clock.now().millisecondsSinceEpoch, hlc, id],
    );
    appendOp(oplogForRecurring(recurringById(id)!));
  }

  /// next_due 推進（確認/跳過共用）＋oplog 快照。
  void advanceNextDue(String id, int nextDueMs, String hlc) {
    _db.execute(
      'UPDATE recurring_transactions SET next_due_date = ?, updated_at = ?, hlc = ?'
      ' WHERE id = ?',
      [nextDueMs, Clock.now().millisecondsSinceEpoch, hlc, id],
    );
    appendOp(oplogForRecurring(recurringById(id)!));
  }

  /// 軟刪除排程（墓標＋oplog 墓標 payload=null——刪除後不再提醒，FR-T5）。
  void softDeleteRecurring(String id, String hlc) {
    _db.execute(
      'UPDATE recurring_transactions SET deleted_at = ?, updated_at = ?, hlc = ?'
      ' WHERE id = ?',
      [Clock.now().millisecondsSinceEpoch, Clock.now().millisecondsSinceEpoch, hlc, id],
    );
    appendOp(OplogRow(
      entity: 'recurring_transactions',
      entityId: id,
      hlc: hlc,
      payload: null,
      packedSeq: null,
    ));
  }

  /// 排程列之 oplog 快照（整列；SDD §5.5.4）。
  OplogRow oplogForRecurring(RecurringRow r) => OplogRow(
        entity: 'recurring_transactions',
        entityId: r.id,
        hlc: r.hlc,
        payload: jsonEncode(r.toSnapshot()),
        packedSeq: null,
      );

  // ── 附件（FR-S4，schema v4；attachments 屬 sync_entity） ──

  /// 附件列寫入 + oplog 追加於同一 DB transaction（SDD §5.1 契約——
  /// 附件中繼資參與同步；blob 本體內容定址另存檔案系統 blobs/）。
  void insertAttachmentWithOplog(AttachmentRow a, OplogRow o) {
    _db.execute('BEGIN');
    try {
      insertAttachment(a);
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void insertAttachment(AttachmentRow a) => _db.execute(
        'INSERT INTO attachments (id, transaction_id, sha256, mime, byte_size,'
        ' created_at, hlc, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          a.id, a.transactionId, a.sha256, a.mime, a.byteSize,
          a.createdAt, a.hlc, a.deletedAt,
        ],
      );

  /// 交易之未刪除附件（S5 關聯斷言）。
  List<AttachmentRow> attachmentsForTransaction(String transactionId) => _db
      .select('SELECT * FROM attachments WHERE transaction_id = ? AND deleted_at IS NULL',
          [transactionId])
      .map(AttachmentRow.fromRow)
      .toList();

  /// 全部未刪除附件（明細 📷 標記索引用，F03-FE）。
  List<AttachmentRow> allAttachments() => _db
      .select('SELECT * FROM attachments WHERE deleted_at IS NULL')
      .map(AttachmentRow.fromRow)
      .toList();

  // ── 同步衝突事件（schema v1 sync_events；FR-Y5/AC-07） ────

  void insertSyncEvent(SyncEventRow e) => _db.execute(
        'INSERT INTO sync_events (id, entity, entity_id, incoming_hlc, overwritten_row,'
        ' created_at, read_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [e.id, e.entity, e.entityId, e.incomingHlc, e.overwrittenRow, e.createdAt, e.readAt],
      );

  List<SyncEventRow> allSyncEvents() => _db
      .select('SELECT * FROM sync_events ORDER BY created_at, id')
      .map(SyncEventRow.fromRow)
      .toList();

  /// 套用遠端整列快照（INSERT OR REPLACE——冪等；SDD §5.5.2 套用端）。
  /// LWW 判定由 BundleApplier 先行（無 hlc 之關聯表直接冪等覆蓋）。
  void applySnapshot(String entity, Map<String, Object?> row) {
    switch (entity) {
      case 'transactions':
        _db.execute(_upsert('transactions', 'id', [
          'kind','amount_minor','currency','fx_rate','account_id','to_account_id',
          'category_id','merchant','note','tags','occurred_at','source',
          'split_group_id','settlement_status','installment_plan_id','installment_seq',
          'created_at','updated_at','hlc','deleted_at',
        ]), [
          row['id'], row['kind'], row['amount_minor'], row['currency'], row['fx_rate'],
          row['account_id'], row['to_account_id'], row['category_id'], row['merchant'],
          row['note'], row['tags'], row['occurred_at'], row['source'], row['split_group_id'],
          row['settlement_status'], row['installment_plan_id'], row['installment_seq'],
          row['created_at'], row['updated_at'], row['hlc'], row['deleted_at'],
        ]);
      case 'accounts':
        _db.execute(_upsert('accounts', 'id', [
          'type','name','currency','opening_amount_minor','color','icon','sort_order',
          'archived','created_at','updated_at','hlc','deleted_at',
        ]), [
          row['id'], row['type'], row['name'], row['currency'], row['opening_amount_minor'],
          row['color'], row['icon'], row['sort_order'], row['archived'],
          row['created_at'], row['updated_at'], row['hlc'], row['deleted_at'],
        ]);
      case 'categories':
        _db.execute(_upsert('categories', 'id', [
          'kind','parent_id','name','icon','color','sort_order','is_system',
          'created_at','updated_at','hlc','deleted_at',
        ]), [
          row['id'], row['kind'], row['parent_id'], row['name'], row['icon'],
          row['color'], row['sort_order'], row['is_system'],
          row['created_at'], row['updated_at'], row['hlc'], row['deleted_at'],
        ]);
      case 'attachments':
        _db.execute(_upsert('attachments', 'id', [
          'transaction_id','sha256','mime','byte_size','created_at','hlc','deleted_at',
        ]), [
          row['id'], row['transaction_id'], row['sha256'], row['mime'], row['byte_size'],
          row['created_at'], row['hlc'], row['deleted_at'],
        ]);
      case 'budgets':
        _db.execute(_upsert('budgets', 'id', [
          'category_id','amount_minor','period_start_day','rollover','created_at',
          'updated_at','hlc','deleted_at',
        ]), [
          row['id'], row['category_id'], row['amount_minor'], row['period_start_day'],
          row['rollover'], row['created_at'], row['updated_at'], row['hlc'], row['deleted_at'],
        ]);
      case 'income_goals':
        _db.execute(_upsert('income_goals', 'id', [
          'amount_minor','period_start_day','created_at','updated_at','hlc','deleted_at',
        ]), [
          row['id'], row['amount_minor'], row['period_start_day'],
          row['created_at'], row['updated_at'], row['hlc'], row['deleted_at'],
        ]);
      default:
        throw UnimplementedError('applySnapshot 未支援 entity：$entity（M5 範圍外）');
    }
  }

  /// INSERT OR REPLACE SQL（pk + 欄位清單）。
  String _upsert(String table, String pk, List<String> cols) =>
      'INSERT OR REPLACE INTO $table ($pk, ${cols.join(', ')})'
      ' VALUES (${List.filled(cols.length + 1, '?').join(', ')})';

  /// 本機列之 hlc（LWW 判定用；不存在回 null）。
  String? localHlc(String entity, String id) {
    final rows = _db.select('SELECT hlc FROM $entity WHERE id = ?', [id]);
    return rows.isEmpty ? null : rows.first['hlc'] as String?;
  }

  /// 本機列之整列快照（衝突事件 overwritten_row 用；不存在回 null）。
  Map<String, Object?>? localRow(String entity, String id) {
    final rows = _db.select('SELECT * FROM $entity WHERE id = ?', [id]);
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
  }

  /// 遠端墓標套用（row=null；實體刪除，oplog 日誌保留）。
  void applyTombstone(String entity, String id) {
    _db.execute('DELETE FROM $entity WHERE id = ?', [id]);
  }

  // ── 同步日誌（SDD §5.5） ──────────────────────────────────

  void appendOp(OplogRow o) => _db.execute(
        'INSERT INTO oplog (entity, entity_id, hlc, payload, packed_seq) VALUES (?, ?, ?, ?, ?)',
        [o.entity, o.entityId, o.hlc, o.payload, o.packedSeq],
      );

  List<OplogRow> allOps() =>
      _db.select('SELECT * FROM oplog ORDER BY seq').map(OplogRow.fromRow).toList();

  /// 未打包 ops（F07 push 資料源：packed_seq IS NULL，SDD §5.5.3）。
  List<OplogRow> unpackedOps() => _db
      .select('SELECT * FROM oplog WHERE packed_seq IS NULL ORDER BY seq')
      .map(OplogRow.fromRow)
      .toList();

  /// 標記未打包 ops 為已打包（bundle seq；SDD §5.5.3 push 收尾）。
  void markOpsPacked(int seq) => _db.execute(
        'UPDATE oplog SET packed_seq = ? WHERE packed_seq IS NULL',
        [seq],
      );

  /// oplog 是否存在該實體之記錄（衝突偵測：本機曾寫入——FR-Y5）。
  bool oplogHasEntityId(String entity, String id) => _db
      .select('SELECT 1 FROM oplog WHERE entity = ? AND entity_id = ? LIMIT 1',
          [entity, id])
      .isNotEmpty;

  /// 備份還原之全表清空（匯入前置；oplog 一併還原快照內容）。
  void clearTable(String table) => _db.execute('DELETE FROM $table');

  /// 備份還原之單列寫入（INSERT OR REPLACE——欄位由快照動態組）。
  void restoreRow(String table, Map<String, Object?> row) {
    final cols = row.keys.toList();
    _db.execute(
      'INSERT OR REPLACE INTO $table (${cols.join(', ')})'
      ' VALUES (${List.filled(cols.length, '?').join(', ')})',
      [for (final c in cols) row[c]],
    );
  }

  /// 交易寫入 + oplog 追加必須同一 transaction（SDD §5.1 儲存事務）。
  ///
  /// [beforeOplog] 為測試 seam：於交易列插入後、oplog 追加前呼叫，拋錯即模擬
  /// 「中斷」，驗證整體 ROLLBACK 不產生孤兒（BDD 步驟：中斷模擬不產生孤兒）。
  void saveTransactionWithOplog(TxRow t, OplogRow o, {void Function(TxRow)? beforeOplog}) {
    _db.execute('BEGIN');
    try {
      insertTransaction(t);
      _ftsReindex(t); // FR-R3：FTS5 影子索引隨寫入維護（環境缺模組時為 no-op）
      beforeOplog?.call(t);
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 交易編輯（FR-T3；PM 2026-10-24）：更新可編輯欄位＋oplog 整列快照於
  /// **同一 DB transaction**（多裝置 LWW 合併語意與其他實體一致；SDD §5.5.4）。
  void updateTransactionWithOplog(TxRow t, OplogRow o) {
    _db.execute('BEGIN');
    try {
      _db.execute(
        'UPDATE transactions SET kind = ?, amount_minor = ?, account_id = ?,'
        ' to_account_id = ?, category_id = ?, merchant = ?, note = ?,'
        ' occurred_at = ?, settlement_status = ?, updated_at = ?, hlc = ?'
        ' WHERE id = ?',
        [
          t.kind, t.amountMinor, t.accountId, t.toAccountId, t.categoryId,
          t.merchant, t.note, t.occurredAt, t.settlementStatus, t.updatedAt,
          t.hlc, t.id,
        ],
      );
      _ftsReindex(t); // FR-R3：FTS5 影子索引隨寫入維護
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 依 id 讀取單筆交易（含墓標）。
  TxRow? transactionById(String id) {
    final rows = _db.select('SELECT * FROM transactions WHERE id = ?', [id]);
    return rows.isEmpty ? null : TxRow.fromRow(rows.first);
  }

  /// 上一筆未刪除交易（FR-Q4 帳戶預設 = 上一筆所用帳戶）。
  /// 排序：occurred_at → created_at → id（後者為同刻之確定性打破）。
  TxRow? lastTransaction() {
    final rows = _db.select(
      'SELECT * FROM transactions WHERE deleted_at IS NULL'
      ' ORDER BY occurred_at DESC, created_at DESC, id DESC LIMIT 1',
    );
    return rows.isEmpty ? null : TxRow.fromRow(rows.first);
  }

  /// 指定商家的未刪除交易（FR-Q4 同商家歷史分類）。
  List<TxRow> transactionsByMerchant(String merchant) => _db
      .select('SELECT * FROM transactions WHERE merchant = ? AND deleted_at IS NULL'
          ' ORDER BY occurred_at DESC', [merchant])
      .map(TxRow.fromRow)
      .toList();

  /// 軟刪除墓標（SDD 原則 5）：UPDATE deleted_at + oplog 墓標（payload=NULL）
  /// 於**同一 transaction**（鏡像 [saveTransactionWithOplog] 契約）。
  /// 已刪除者拋 StateError（防重複墓標——同步後多刪，acceptance F01 S1.8）。
  void softDeleteTransactionWithOplog(
    String id,
    OplogRow o, {
    required int deletedAt,
    required String hlc,
  }) {
    final tx = transactionById(id);
    if (tx == null) {
      throw StateError('軟刪除失敗：交易不存在 $id');
    }
    if (tx.deletedAt != null) {
      throw StateError('軟刪除失敗：交易已為墓標 $id');
    }
    _db.execute('BEGIN');
    try {
      _db.execute(
        'UPDATE transactions SET deleted_at = ?, updated_at = ?, hlc = ? WHERE id = ?',
        [deletedAt, deletedAt, hlc, id],
      );
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 實體清除 deleted_at <= cutoffMs 之墓標列（FR-T3 保留期屆滿，F02 S2.5）。
  /// oplog 墓標保留（同步日誌完整性，GC 屬 F07）。回傳清除筆數；冪等（無候選回 0）。
  int purgeTransactionsDeletedBefore(int cutoffMs) {
    _db.execute('BEGIN');
    try {
      final count = _db
          .select(
              'SELECT COUNT(*) AS c FROM transactions'
              ' WHERE deleted_at IS NOT NULL AND deleted_at <= ?',
              [cutoffMs])
          .first['c'] as int;
      if (count > 0) {
        _db.execute(
          'DELETE FROM transactions WHERE deleted_at IS NOT NULL AND deleted_at <= ?',
          [cutoffMs],
        );
      }
      _db.execute('COMMIT');
      return count;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// **單筆**實體清除墓標（「最近刪除」→「永久刪除」；PM 2026-10-24）。
  /// 語意**完全同** [purgeTransactionsDeletedBefore]：實體刪列、**oplog 墓標保留**
  /// （軟刪除當下已寫入 payload=NULL 墓標——其他裝置的刪除結果不受影響，
  /// 同步安全；與 30 天屆滿自動清除同一條路徑）。
  /// - 未刪除之交易拋 StateError（防「永久刪除」誤傷未刪除資料）。
  /// - 已清除/不存在回 0（冪等——連點兩次不報錯）。
  int purgeTombstoneById(String id) {
    final tx = transactionById(id);
    if (tx == null) return 0;
    if (tx.deletedAt == null) {
      throw StateError('永久刪除失敗：交易未刪除 $id');
    }
    _db.execute('DELETE FROM transactions WHERE id = ?', [id]);
    return 1;
  }

  /// 還原墓標（FR-T3 30 天內，acceptance F02 S2.5 步驟 3）：deleted_at → NULL
  /// + oplog **整列快照**（非墓標——還原是 UPDATE，同步端以快照覆蓋）於
  /// **同一 transaction**（鏡像 [softDeleteTransactionWithOplog] 契約）。
  /// 未刪除/不存在者拋 StateError（防還原幻影）。
  void restoreTransactionWithOplog(
    String id,
    OplogRow o, {
    required int restoredAt,
    required String hlc,
  }) {
    final tx = transactionById(id);
    if (tx == null) {
      throw StateError('還原失敗：交易不存在 $id');
    }
    if (tx.deletedAt == null) {
      throw StateError('還原失敗：交易未刪除 $id');
    }
    _db.execute('BEGIN');
    try {
      _db.execute(
        'UPDATE transactions SET deleted_at = NULL, updated_at = ?, hlc = ? WHERE id = ?',
        [restoredAt, hlc, id],
      );
      appendOp(o);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ── 設定（key-value；device.* 為 per-device 不入 oplog） ──

  void setSetting(String key, String value) => _db.execute(
        'INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)'
        ' ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at',
        [key, value, DateTime.now().millisecondsSinceEpoch],
      );

  String? getSetting(String key) {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }
}

// ── Row 型別（欄位對映 data-spec.dbml） ──────────────────────

class AccountRow {
  const AccountRow({
    required this.id,
    required this.type,
    required this.name,
    required this.currency,
    required this.openingAmountMinor,
    this.includeInTotals = true,
    required this.archived,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
  });

  final String id;
  final String type;
  final String name;
  final String currency;
  final int openingAmountMinor;

  /// 是否計入合併統計（SPEC FR-A2/A6/A7；預設 true——總覽資產/負債/淨值
  /// 僅計入 `includeInTotals && !archived` 之帳戶）。
  final bool includeInTotals;
  final bool archived;
  final int createdAt;
  final int updatedAt;
  final String hlc;

  factory AccountRow.fromRow(Map<String, Object?> r) => AccountRow(
        id: r['id'] as String,
        type: r['type'] as String,
        name: r['name'] as String,
        currency: r['currency'] as String,
        openingAmountMinor: r['opening_amount_minor'] as int,
        includeInTotals: (r['include_in_totals'] as int? ?? 1) == 1,
        archived: (r['archived'] as int) == 1,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
        hlc: r['hlc'] as String,
      );

  /// oplog payload 之整列快照（SDD §5.5.4）。
  Map<String, Object?> toSnapshot() => {
        'id': id,
        'type': type,
        'name': name,
        'currency': currency,
        'opening_amount_minor': openingAmountMinor,
        'include_in_totals': includeInTotals,
        'archived': archived,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'hlc': hlc,
      };

  AccountRow copyWith({
    String? type,
    String? name,
    int? openingAmountMinor,
    bool? includeInTotals,
    bool? archived,
    int? updatedAt,
    String? hlc,
  }) =>
      AccountRow(
        id: id,
        type: type ?? this.type,
        name: name ?? this.name,
        currency: currency,
        openingAmountMinor: openingAmountMinor ?? this.openingAmountMinor,
        includeInTotals: includeInTotals ?? this.includeInTotals,
        archived: archived ?? this.archived,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        hlc: hlc ?? this.hlc,
      );
}

class CategoryRow {
  const CategoryRow({
    required this.id,
    required this.kind,
    required this.parentId,
    required this.name,
    this.icon,
    this.color,
    this.sortOrder,
    this.isSystem = false,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
    this.deletedAt,
  });

  final String id;
  final String kind;
  final String? parentId;
  final String name;

  /// 圖示與顏色（SPEC FR-B1；分類管理設定用）。
  final String? icon;
  final String? color;

  /// 排序（FR-B1；連續遞增整數，CategoryService.reorder 維護）。
  final int? sortOrder;
  final bool isSystem;
  final int createdAt;
  final int updatedAt;
  final String hlc;
  final int? deletedAt;

  factory CategoryRow.fromRow(Map<String, Object?> r) => CategoryRow(
        id: r['id'] as String,
        kind: r['kind'] as String,
        parentId: r['parent_id'] as String?,
        name: r['name'] as String,
        icon: r['icon'] as String?,
        color: r['color'] as String?,
        sortOrder: r['sort_order'] as int?,
        isSystem: (r['is_system'] as int) == 1,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
        hlc: r['hlc'] as String,
        deletedAt: r['deleted_at'] as int?,
      );

  /// oplog payload 之整列快照（SDD §5.5.4）。
  Map<String, Object?> toSnapshot() => {
        'id': id,
        'kind': kind,
        'parent_id': parentId,
        'name': name,
        'icon': icon,
        'color': color,
        'sort_order': sortOrder,
        'is_system': isSystem,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'hlc': hlc,
        'deleted_at': deletedAt,
      };

  CategoryRow copyWith({
    String? name,
    String? icon,
    String? color,
    int? sortOrder,
    bool? isSystem,
    int? updatedAt,
    String? hlc,
    int? deletedAt,
  }) =>
      CategoryRow(
        id: id,
        kind: kind,
        parentId: parentId,
        name: name ?? this.name,
        icon: icon ?? this.icon,
        color: color ?? this.color,
        sortOrder: sortOrder ?? this.sortOrder,
        isSystem: isSystem ?? this.isSystem,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        hlc: hlc ?? this.hlc,
        deletedAt: deletedAt ?? this.deletedAt,
      );
}

class TxRow {
  const TxRow({
    required this.id,
    required this.kind,
    required this.amountMinor,
    required this.currency,
    this.fxRate,
    required this.accountId,
    required this.toAccountId,
    required this.categoryId,
    required this.merchant,
    required this.note,
    required this.occurredAt,
    required this.source,
    required this.settlementStatus,
    this.splitGroupId,
    this.installmentSeq,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
    this.deletedAt,
  });

  final String id;
  final String kind;

  /// 正數；方向由 [kind] 與帳戶語意決定（SDD §4.2）。
  final int amountMinor;

  /// 交易幣別（原幣；TWD 為本位幣，FR-T4）。
  final String currency;

  /// 非本位幣匯率（原幣 1 單位兌本位幣；FR-T4；null＝本位幣）。
  final double? fxRate;
  final String accountId;
  final String? toAccountId;
  final String? categoryId;
  final String? merchant;
  final String? note;
  final int occurredAt;
  final String source;
  final String settlementStatus;

  final int createdAt;
  final int updatedAt;
  final String hlc;

  /// 拆分群組（FR-T6；同群組子交易共享；null＝非拆分）。
  final String? splitGroupId;

  /// 分期序號（FR-C7；1..N；null＝非分期）。
  final int? installmentSeq;

  /// 墓標（SDD 原則 5）；null = 未刪除。
  final int? deletedAt;

  factory TxRow.fromRow(Map<String, Object?> r) => TxRow(
        id: r['id'] as String,
        kind: r['kind'] as String,
        amountMinor: r['amount_minor'] as int,
        currency: r['currency'] as String,
        fxRate: r['fx_rate'] as double?,
        accountId: r['account_id'] as String,
        toAccountId: r['to_account_id'] as String?,
        categoryId: r['category_id'] as String?,
        merchant: r['merchant'] as String?,
        note: r['note'] as String?,
        occurredAt: r['occurred_at'] as int,
        source: r['source'] as String,
        settlementStatus: r['settlement_status'] as String,
        splitGroupId: r['split_group_id'] as String?,
        installmentSeq: r['installment_seq'] as int?,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
        hlc: r['hlc'] as String,
        deletedAt: r['deleted_at'] as int?,
      );

  /// 複製並覆寫（交易編輯；PM 2026-10-24）。可空欄位以 clearX 明確清空。
  TxRow copyWith({
    String? kind,
    int? amountMinor,
    String? accountId,
    String? toAccountId,
    bool clearToAccount = false,
    String? categoryId,
    bool clearCategory = false,
    String? merchant,
    bool clearMerchant = false,
    String? note,
    bool clearNote = false,
    int? occurredAt,
    String? settlementStatus,
    int? updatedAt,
    String? hlc,
    int? deletedAt,
  }) =>
      TxRow(
        id: id,
        kind: kind ?? this.kind,
        amountMinor: amountMinor ?? this.amountMinor,
        currency: currency,
        fxRate: fxRate,
        accountId: accountId ?? this.accountId,
        toAccountId: clearToAccount ? null : (toAccountId ?? this.toAccountId),
        categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
        merchant: clearMerchant ? null : (merchant ?? this.merchant),
        note: clearNote ? null : (note ?? this.note),
        occurredAt: occurredAt ?? this.occurredAt,
        source: source,
        settlementStatus: settlementStatus ?? this.settlementStatus,
        splitGroupId: splitGroupId,
        installmentSeq: installmentSeq,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        hlc: hlc ?? this.hlc,
        deletedAt: deletedAt ?? this.deletedAt,
      );

  /// oplog payload 之整列快照（SDD §5.5.4：非欄位 diff，套用冪等）。
  Map<String, Object?> toSnapshot() => {
        'id': id,
        'kind': kind,
        'amount_minor': amountMinor,
        'currency': currency,
        'fx_rate': fxRate,
        'account_id': accountId,
        'to_account_id': toAccountId,
        'category_id': categoryId,
        'merchant': merchant,
        'note': note,
        'occurred_at': occurredAt,
        'source': source,
        'settlement_status': settlementStatus,
        'split_group_id': splitGroupId,
        'installment_seq': installmentSeq,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'hlc': hlc,
        'deleted_at': deletedAt,
      };
}

/// 預算列（schema v2，data-spec.dbml budgets；category_id NULL＝總預算 FR-B2）。
class BudgetRow {
  const BudgetRow({
    required this.id,
    this.categoryId,
    required this.amountMinor,
    required this.periodStartDay,
    required this.rollover,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
  });

  final String id;
  final String? categoryId;

  /// 正數 minor units。
  final int amountMinor;

  /// 1..28 週期起始日（FR-B2）。
  final int periodStartDay;
  final bool rollover;
  final int createdAt;
  final int updatedAt;
  final String hlc;

  factory BudgetRow.fromRow(Map<String, Object?> r) => BudgetRow(
        id: r['id'] as String,
        categoryId: r['category_id'] as String?,
        amountMinor: r['amount_minor'] as int,
        periodStartDay: r['period_start_day'] as int,
        rollover: (r['rollover'] as int) == 1,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
        hlc: r['hlc'] as String,
      );

  /// oplog payload 之整列快照（SDD §5.5.4）。
  Map<String, Object?> toSnapshot() => {
        'id': id,
        'category_id': categoryId,
        'amount_minor': amountMinor,
        'period_start_day': periodStartDay,
        'rollover': rollover,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'hlc': hlc,
      };
}

/// 收入目標列（schema v2，data-spec.dbml income_goals；單一目標模型 FR-B6）。
class IncomeGoalRow {
  const IncomeGoalRow({
    required this.id,
    required this.amountMinor,
    required this.periodStartDay,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
  });

  final String id;
  final int amountMinor;
  final int periodStartDay;
  final int createdAt;
  final int updatedAt;
  final String hlc;

  factory IncomeGoalRow.fromRow(Map<String, Object?> r) => IncomeGoalRow(
        id: r['id'] as String,
        amountMinor: r['amount_minor'] as int,
        periodStartDay: r['period_start_day'] as int,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
        hlc: r['hlc'] as String,
      );

  /// oplog payload 之整列快照（SDD §5.5.4）。
  Map<String, Object?> toSnapshot() => {
        'id': id,
        'amount_minor': amountMinor,
        'period_start_day': periodStartDay,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'hlc': hlc,
      };
}

/// 信用卡明細列（schema v3，data-spec.dbml credit_card_details；FR-A3）。
/// device-local（不在 sync_entity——卡片設定不參與同步）。
class CreditCardDetailRow {
  const CreditCardDetailRow({
    required this.accountId,
    this.last4,
    required this.statementDay,
    required this.dueOffsetDays,
    this.linkedAccountId,
    required this.boundaryRule,
    this.creditLimitMinor,
    this.effectiveFrom,
  });

  final String accountId;
  final String? last4;

  /// 1..28；29-31 遇小月 clamp 月底。
  final int statementDay;

  /// 繳款日 = 結帳日 + N（FR-A3）。
  final int dueOffsetDays;

  /// 扣款帳戶；null = 手動標記（FR-C4）。
  final String? linkedAccountId;

  /// include：結帳日當天消費算本期（預設，FR-C2）。
  final String boundaryRule;
  final int? creditLimitMinor;

  /// 結帳日修改自下期生效（FR-A3/S4.11）。
  final int? effectiveFrom;

  factory CreditCardDetailRow.fromRow(Map<String, Object?> r) => CreditCardDetailRow(
        accountId: r['account_id'] as String,
        last4: r['last4'] as String?,
        statementDay: r['statement_day'] as int,
        dueOffsetDays: r['due_offset_days'] as int,
        linkedAccountId: r['linked_account_id'] as String?,
        boundaryRule: r['boundary_rule'] as String,
        creditLimitMinor: r['credit_limit_minor'] as int?,
        effectiveFrom: r['effective_from'] as int?,
      );
}

/// 帳單列（schema v3，FR-C3）。
class StatementRow {
  const StatementRow({
    required this.id,
    required this.accountId,
    required this.periodStart,
    required this.periodEnd,
    required this.statementDate,
    required this.dueDate,
    required this.totalMinor,
    required this.paidMinor,
    required this.status,
    this.paidAt,
    required this.overdueNotified,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
    this.deletedAt,
  });

  final String id;
  final String accountId;
  final int periodStart;
  final int periodEnd;
  final int statementDate;
  final int dueDate;
  final int totalMinor;
  final int paidMinor;

  /// issued | partial | paid（statement_status）。
  final String status;
  final int? paidAt;
  final bool overdueNotified;
  final int createdAt;
  final int updatedAt;
  final String hlc;
  final int? deletedAt;

  factory StatementRow.fromRow(Map<String, Object?> r) => StatementRow(
        id: r['id'] as String,
        accountId: r['account_id'] as String,
        periodStart: r['period_start'] as int,
        periodEnd: r['period_end'] as int,
        statementDate: r['statement_date'] as int,
        dueDate: r['due_date'] as int,
        totalMinor: r['total_minor'] as int,
        paidMinor: r['paid_minor'] as int,
        status: r['status'] as String,
        paidAt: r['paid_at'] as int?,
        overdueNotified: (r['overdue_notified'] as int) == 1,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
        hlc: r['hlc'] as String,
        deletedAt: r['deleted_at'] as int?,
      );

  /// 剩餘應繳。
  int get remainingMinor => totalMinor - paidMinor;

  Map<String, Object?> toSnapshot() => {
        'id': id,
        'account_id': accountId,
        'period_start': periodStart,
        'period_end': periodEnd,
        'statement_date': statementDate,
        'due_date': dueDate,
        'total_minor': totalMinor,
        'paid_minor': paidMinor,
        'status': status,
        'paid_at': paidAt,
        'overdue_notified': overdueNotified,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'hlc': hlc,
        'deleted_at': deletedAt,
      };
}

/// 分期計畫列（schema v3，FR-C7）。
class InstallmentPlanRow {
  const InstallmentPlanRow({
    required this.id,
    required this.accountId,
    required this.totalMinor,
    required this.installments,
    required this.firstDate,
    this.note,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
    this.deletedAt,
  });

  final String id;
  final String accountId;
  final int totalMinor;
  final int installments;
  final int firstDate;
  final String? note;
  final int createdAt;
  final int updatedAt;
  final String hlc;
  final int? deletedAt;

  factory InstallmentPlanRow.fromRow(Map<String, Object?> r) =>
      InstallmentPlanRow(
        id: r['id'] as String,
        accountId: r['account_id'] as String,
        totalMinor: r['total_minor'] as int,
        installments: r['installments'] as int,
        firstDate: r['first_date'] as int,
        note: r['note'] as String?,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
        hlc: r['hlc'] as String,
        deletedAt: r['deleted_at'] as int?,
      );
}

/// 附件列（schema v4，data-spec.dbml attachments；FR-S4——sha256 內容定址）。
class AttachmentRow {
  const AttachmentRow({
    required this.id,
    required this.transactionId,
    required this.sha256,
    this.mime,
    this.byteSize,
    required this.createdAt,
    required this.hlc,
    this.deletedAt,
  });

  final String id;

  /// 關聯交易（Ref: delete cascade——dbml；交易刪除連動由 UseCase 維護）。
  final String transactionId;

  /// 壓縮內容 sha256（檔名 blobs/{sha256} 與雲端 blobs/{sha256}.bin.enc 同源；
  /// 同步去重 SDD §5.5.6）。
  final String sha256;
  final String? mime;
  final int? byteSize;
  final int createdAt;
  final String hlc;
  final int? deletedAt;

  factory AttachmentRow.fromRow(Map<String, Object?> r) => AttachmentRow(
        id: r['id'] as String,
        transactionId: r['transaction_id'] as String,
        sha256: r['sha256'] as String,
        mime: r['mime'] as String?,
        byteSize: r['byte_size'] as int?,
        createdAt: r['created_at'] as int,
        hlc: r['hlc'] as String,
        deletedAt: r['deleted_at'] as int?,
      );

  /// oplog payload 之整列快照（SDD §5.5.4）。
  Map<String, Object?> toSnapshot() => {
        'id': id,
        'transaction_id': transactionId,
        'sha256': sha256,
        'mime': mime,
        'byte_size': byteSize,
        'created_at': createdAt,
        'hlc': hlc,
        'deleted_at': deletedAt,
      };
}

/// 定期交易排程列（schema v5，data-spec.dbml recurring_transactions；FR-T5 提醒確認制）。
class RecurringRow {
  const RecurringRow({
    required this.id,
    required this.name,
    required this.kind,
    required this.amountMinor,
    required this.accountId,
    required this.categoryId,
    required this.frequency,
    this.intervalDays,
    required this.anchorDate,
    required this.endType,
    this.endCount,
    this.endDate,
    required this.nextDueDate,
    required this.reminderCount,
    required this.paused,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
    this.deletedAt,
  });

  final String id;
  final String name;

  /// expense | income（模板語意；確認時可改且不回寫——FR-T5）。
  final String kind;
  final int amountMinor;
  final String accountId;
  final String categoryId;

  /// daily | weekly | monthly | yearly | custom（custom 用 intervalDays）。
  final String frequency;
  final int? intervalDays;

  /// 首次到期日（ms）。
  final int anchorDate;

  /// never | count | date。
  final String endType;
  final int? endCount;
  final int? endDate;

  /// 下次到期日（ms；確認/跳過後推進）。
  final int nextDueDate;

  /// 同期已提醒次數；≥3 停止推播（FR-T5）。
  final int reminderCount;

  /// 逾期 3 次未處理→true（S6.5）。
  final bool paused;
  final int createdAt;
  final int updatedAt;
  final String hlc;
  final int? deletedAt;

  factory RecurringRow.fromRow(Map<String, Object?> r) => RecurringRow(
        id: r['id'] as String,
        name: r['name'] as String,
        kind: r['kind'] as String,
        amountMinor: r['amount_minor'] as int,
        accountId: r['account_id'] as String,
        categoryId: r['category_id'] as String,
        frequency: r['frequency'] as String,
        intervalDays: r['interval_days'] as int?,
        anchorDate: r['anchor_date'] as int,
        endType: r['end_type'] as String,
        endCount: r['end_count'] as int?,
        endDate: r['end_date'] as int?,
        nextDueDate: r['next_due_date'] as int,
        reminderCount: r['reminder_count'] as int,
        paused: (r['paused'] as int) == 1,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
        hlc: r['hlc'] as String,
        deletedAt: r['deleted_at'] as int?,
      );

  /// oplog payload 之整列快照（SDD §5.5.4）。
  Map<String, Object?> toSnapshot() => {
        'id': id,
        'name': name,
        'kind': kind,
        'amount_minor': amountMinor,
        'account_id': accountId,
        'category_id': categoryId,
        'frequency': frequency,
        'interval_days': intervalDays,
        'anchor_date': anchorDate,
        'end_type': endType,
        'end_count': endCount,
        'end_date': endDate,
        'next_due_date': nextDueDate,
        'reminder_count': reminderCount,
        'paused': paused ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'hlc': hlc,
        'deleted_at': deletedAt,
      };
}

/// 同步衝突事件列（schema v1 sync_events；FR-Y5——LWW 落敗被覆蓋內容唯讀快照）。
class SyncEventRow {
  const SyncEventRow({
    required this.id,
    required this.entity,
    required this.entityId,
    required this.incomingHlc,
    this.overwrittenRow,
    required this.createdAt,
    this.readAt,
  });

  final String id;
  final String entity;
  final String entityId;

  /// 勝出的遠端版本。
  final String incomingHlc;

  /// 被覆蓋內容 JSON 快照（衝突檢視用）。
  final String? overwrittenRow;
  final int createdAt;
  final int? readAt;

  factory SyncEventRow.fromRow(Map<String, Object?> r) => SyncEventRow(
        id: r['id'] as String,
        entity: r['entity'] as String,
        entityId: r['entity_id'] as String,
        incomingHlc: r['incoming_hlc'] as String,
        overwrittenRow: r['overwritten_row'] as String?,
        createdAt: r['created_at'] as int,
        readAt: r['read_at'] as int?,
      );
}

class OplogRow {
  const OplogRow({
    required this.entity,
    required this.entityId,
    required this.hlc,
    required this.payload,
    required this.packedSeq,
    this.seq,
  });

  final int? seq;
  final String entity;
  final String entityId;
  final String hlc;
  final String? payload;
  final int? packedSeq;

  factory OplogRow.fromRow(Map<String, Object?> r) => OplogRow(
        seq: r['seq'] as int,
        entity: r['entity'] as String,
        entityId: r['entity_id'] as String,
        hlc: r['hlc'] as String,
        payload: r['payload'] as String?,
        packedSeq: r['packed_seq'] as int?,
      );
}
