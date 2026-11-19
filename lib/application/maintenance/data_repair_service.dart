import 'dart:convert';

import '../../core/clock.dart';
import '../../core/hlc.dart';
import '../../data/sqlite/app_database.dart';

/// 一次性資料修復（PM 2026-11-19 實測資料發現的兩類損害；冪等——
/// settings `repair.v1.done` 已設即跳過）：
///
/// 1. **信用卡支出/退款 settlement `none`→`pending`**：此前快記/匯入對
///    信用卡帳戶一律 'none' → 「應付」恆 0（明細 chips/總覽/信用卡頁失真）。
/// 2. **孤兒交易軟刪除**：帳戶已刪除但交易殘留（帳戶刪除未連動的歷史資料）
///    → 明細/統計加總錯誤。走墓標（「最近刪除」可還原；同步安全）。
///
/// 每筆修改都寫 oplog（同步裝置間一致）；僅處理 `deleted_at IS NULL`。
class DataRepairService {
  DataRepairService(this._db, {this.deviceId = 'device-local'});

  final AppDatabase _db;
  final String deviceId;

  static const String _flagKey = 'repair.v1.done';

  bool get isDone => _db.getSetting(_flagKey) == '1';

  /// 執行修復。回傳摘要（修復筆數）。
  RepairReport run() {
    if (isDone) return const RepairReport(creditPendingFixed: 0, orphansFixed: 0);
    var creditFixed = 0;
    var orphans = 0;

    // 1. 信用卡 none → pending（支出/退款）
    final creditRows = _db.select(
      "SELECT t.id FROM transactions t "
      "JOIN accounts a ON a.id = t.account_id "
      "WHERE t.deleted_at IS NULL AND a.type = 'credit' "
      "AND t.settlement_status = 'none' "
      "AND t.kind IN ('expense', 'refund')",
    );
    for (final r in creditRows) {
      final tx = _db.transactionById(r['id'] as String);
      if (tx == null) continue;
      final now = Clock.now().millisecondsSinceEpoch;
      final hlc = Hlc.now(deviceId).toString();
      final fixed = TxRow(
        id: tx.id,
        kind: tx.kind,
        amountMinor: tx.amountMinor,
        currency: tx.currency,
        fxRate: tx.fxRate,
        accountId: tx.accountId,
        toAccountId: tx.toAccountId,
        categoryId: tx.categoryId,
        merchant: tx.merchant,
        note: tx.note,
        occurredAt: tx.occurredAt,
        source: tx.source,
        settlementStatus: 'pending',
        splitGroupId: tx.splitGroupId,
        installmentSeq: tx.installmentSeq,
        createdAt: tx.createdAt,
        updatedAt: now,
        hlc: hlc,
        deletedAt: tx.deletedAt,
      );
      _db.updateTransactionWithOplog(
        fixed,
        OplogRow(
          entity: 'transactions',
          entityId: fixed.id,
          hlc: hlc,
          payload: jsonEncode(fixed.toSnapshot()),
          packedSeq: null,
        ),
      );
      creditFixed++;
    }

    // 2. 孤兒交易（帳戶已不存在）→ 軟刪除（墓標）
    final orphanRows = _db.select(
      'SELECT id FROM transactions WHERE deleted_at IS NULL AND '
      'account_id NOT IN (SELECT id FROM accounts)',
    );
    for (final r in orphanRows) {
      final txId = r['id'] as String;
      final nowMs = Clock.now().millisecondsSinceEpoch;
      final hlc = Hlc.now(deviceId).toString();
      _db.softDeleteTransactionWithOplog(
        txId,
        OplogRow(
          entity: 'transactions',
          entityId: txId,
          hlc: hlc,
          payload: null, // 墓標（SDD §5.5.4）
          packedSeq: null,
        ),
        deletedAt: nowMs,
        hlc: hlc,
      );
      orphans++;
    }

    _db.setSetting(_flagKey, '1');
    return RepairReport(creditPendingFixed: creditFixed, orphansFixed: orphans);
  }
}

class RepairReport {
  const RepairReport({required this.creditPendingFixed, required this.orphansFixed});
  final int creditPendingFixed;
  final int orphansFixed;
}
