import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/clock.dart';
import '../../core/hlc.dart';
import '../../data/sqlite/app_database.dart';
import '../../domain/entities/transaction.dart';

/// 交易驗證失敗（[message] 為 FE 顯示契約；BE BDD 斷言同一訊息，F02 S2.1）。
class TransactionValidationException implements Exception {
  const TransactionValidationException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 儲存結果：回傳入庫交易 id（FE 對話框/Undo 用）。
class SaveTransactionResult {
  const SaveTransactionResult(this.transactionId);
  final String transactionId;
}

/// 儲存事務 UseCase（FR-Q5／SDD §5.1）。
///
/// 契約：
/// - 交易與 oplog 於**同一 DB transaction** 寫入（[AppDatabase.saveTransactionWithOplog]），
///   保證不產生「有交易但沒有同步記錄」的孤兒（BDD：中斷模擬不產生孤兒）。
/// - oplog payload 為整列快照、packed_seq = null（待 SyncCoordinator 打包，F07）——
///   離線時僅落地本地（local-first，S1.10），上線後補同步。
/// - 金額一律整數 minor units 且為正（方向由 kind 決定，SDD §4.2）。
/// - [afterSave]：入庫成功後之**警示同步鉤子**（FR-B4 冪等 sync 點；
///   F05 BudgetAlertService——通知 spy/正式通知皆 fire-and-forget）。
class SaveTransactionUseCase {
  SaveTransactionUseCase(this._db, {this.deviceId = 'device-local', this.afterSave});

  final AppDatabase _db;

  /// HLC 裝置 id（M1 本地單機；F07 多裝置時由裝置註冊提供）。
  final String deviceId;

  /// 入庫成功後呼叫（可為 null——F01/F02 純情境不接警示）。
  final void Function()? afterSave;

  /// 記一筆（F02 擴充：kind 預設支出；transfer/repayment 須 [toAccountId]）。
  ///
  /// [occurredAt] 允許回填（S1.5）；id 以 UUIDv7（data-spec）；HLC 依 [Clock] 取時。
  /// 契約：
  /// - 金額一律整數 minor units 且為正（方向由 kind 決定，SDD §4.2）。
  /// - transfer/repayment 須指定**相異**目標帳戶（同帳戶轉帳 UI 阻擋，BE 為後備防線）。
  /// - transfer/repayment 不適用分類（S2.6：還款固定還款語意，無分類選擇器）。
  SaveTransactionResult execute({
    required String accountId,
    String? categoryId,
    required int amountMinor,
    required DateTime occurredAt,
    String? merchant,
    String? note,
    TxKind kind = TxKind.expense,
    String? toAccountId,
    String settlementStatus = 'none',
    String currency = 'TWD',
    double? fxRate,
    String source = 'manual',
  }) {
    // FR-T4：非本位幣須有匯率（不猜測，S10.2 邊界）。
    if (currency != 'TWD' && fxRate == null) {
      throw const TransactionValidationException('驗證失敗：請輸入匯率');
    }
    if (amountMinor <= 0) {
      // F02 S2.1：金額必填且大於 0（0 或空值皆不得入庫；訊息為 FE 顯示契約）。
      throw const TransactionValidationException('驗證失敗：金額必須大於 0');
    }
    final isCrossAccount = kind == TxKind.transfer || kind == TxKind.repayment;
    if (isCrossAccount && (toAccountId == null || toAccountId == accountId)) {
      throw const TransactionValidationException('驗證失敗：轉帳須指定相異目標帳戶');
    }
    // PM 2026-11-19 修復：信用卡支出/退款＝**預扣（pending）**——此前一律
    // 'none' → 信用卡「應付」恆 0（明細 chips/總覽/信用卡頁全部失真）。
    var effectiveStatus = settlementStatus;
    if (settlementStatus == 'none' &&
        (kind == TxKind.expense || kind == TxKind.refund)) {
      final accType = _db
          .select('SELECT type FROM accounts WHERE id = ?', [accountId])
          .firstOrNull?['type'] as String?;
      if (accType == 'credit') effectiveStatus = 'pending';
    }
    final now = Clock.now();
    final row = TxRow(
      id: const Uuid().v7(),
      kind: kind.name,
      amountMinor: amountMinor,
      currency: currency,
      fxRate: fxRate,
      accountId: accountId,
      toAccountId: isCrossAccount ? toAccountId : null,
      categoryId: isCrossAccount ? null : categoryId,
      merchant: merchant,
      note: note,
      occurredAt: occurredAt.millisecondsSinceEpoch,
      source: source,
      // F05 S5.3：信用卡預扣（pending）——預算「承諾支出」口徑；完整帳單語意屬 F04。
      settlementStatus: effectiveStatus,
      createdAt: now.millisecondsSinceEpoch,
      updatedAt: now.millisecondsSinceEpoch,
      hlc: Hlc.now(deviceId).toString(),
    );
    _db.saveTransactionWithOplog(
      row,
      OplogRow(
        entity: 'transactions',
        entityId: row.id,
        hlc: row.hlc,
        payload: jsonEncode(row.toSnapshot()),
        packedSeq: null,
      ),
    );
    // FR-B4：入庫後冪等同步預算警示（sync 點①；F05）。
    afterSave?.call();
    return SaveTransactionResult(row.id);
  }

  /// 拆分交易（FR-T6，acceptance S2.7）：一次儲存 N 筆子交易——
  /// 同 [splitGroupId]（UUIDv7）、同帳戶、同時間；**總額守恆**（子項加總 ≠
  /// 總額即驗證失敗，UI 無法儲存）；單一 DB transaction（各筆 oplog＋FTS）。
  ///
  /// 回傳各子交易 id（明細呈現「拆分」樣式用）。
  List<String> executeSplit({
    required String accountId,
    required int totalMinor,
    required List<({String? categoryId, int amountMinor})> items,
    required DateTime occurredAt,
    String? merchant,
    String? note,
  }) {
    if (items.isEmpty) {
      throw const TransactionValidationException('驗證失敗：拆分至少一個子項');
    }
    final sum = items.fold<int>(0, (s, i) => s + i.amountMinor);
    if (sum != totalMinor) {
      throw const TransactionValidationException('驗證失敗：子項加總須等於總額');
    }
    final groupId = const Uuid().v7();
    final now = Clock.now();
    final nowMs = now.millisecondsSinceEpoch;
    final hlc = Hlc.now(deviceId).toString();
    final rows = <TxRow>[];
    final ops = <OplogRow>[];
    for (final item in items) {
      final row = TxRow(
        id: const Uuid().v7(),
        kind: 'expense',
        amountMinor: item.amountMinor,
        currency: 'TWD',
        accountId: accountId,
        toAccountId: null,
        categoryId: item.categoryId,
        merchant: merchant,
        note: note,
        occurredAt: occurredAt.millisecondsSinceEpoch,
        source: 'manual',
        settlementStatus: 'none',
        splitGroupId: groupId,
        createdAt: nowMs,
        updatedAt: nowMs,
        hlc: hlc,
      );
      rows.add(row);
      ops.add(OplogRow(
        entity: 'transactions',
        entityId: row.id,
        hlc: hlc,
        payload: jsonEncode(row.toSnapshot()),
        packedSeq: null,
      ));
    }
    _db.saveTransactionsSplitWithOplog(rows, ops);
    afterSave?.call();
    return [for (final r in rows) r.id];
  }
}
