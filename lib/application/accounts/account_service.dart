import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/clock.dart';
import '../../core/hlc.dart';
import '../../data/sqlite/app_database.dart';
import '../../domain/services/balance_calculator.dart';
import '../mappers.dart';

/// 帳戶操作被拒（FR-A2；訊息可直接顯示給使用者）。
class AccountInUseException implements Exception {
  const AccountInUseException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 帳戶 CRUD 服務（SPEC FR-A7；SDD §5.6）。
///
/// **契約**：每次變更＝`accounts`＋`oplog` 同 transaction（SDD §5.1），
/// payload 為整列快照——沿用既有 LWW 合併，無新同步邏輯。
/// 刪除把關（FR-A2）：**信用卡有未結算交易（未繳 > 0）→ 拒絕**（提示改封存）。
class AccountService {
  AccountService(this._db, {this.deviceId = 'device-local'});

  final AppDatabase _db;
  final String deviceId;

  static const _uuid = Uuid();
  static const calc = BalanceCalculator();

  /// 新增帳戶（回傳新列；accounts＋oplog 同 transaction）。
  AccountRow create({
    required String type,
    required String name,
    int openingMinor = 0,
    bool includeInTotals = true,
    String currency = 'TWD',
    String? id,
  }) {
    final nowMs = Clock.now().millisecondsSinceEpoch;
    final hlc = Hlc.now(deviceId).toString();
    final row = AccountRow(
      id: id ?? _uuid.v7(),
      type: type,
      name: name,
      currency: currency,
      openingAmountMinor: openingMinor,
      includeInTotals: includeInTotals,
      archived: false,
      createdAt: nowMs,
      updatedAt: nowMs,
      hlc: hlc,
    );
    _db.insertAccountWithOplog(row, _op(row, hlc));
    return row;
  }

  /// 編輯帳戶（名稱／類型／期初／是否計入合併／封存；FR-A7）。
  AccountRow update(
    String id, {
    String? name,
    String? type,
    int? openingMinor,
    bool? includeInTotals,
    bool? archived,
  }) {
    final current = _find(id);
    final hlc = Hlc.now(deviceId).toString();
    final row = current.copyWith(
      name: name,
      type: type,
      openingAmountMinor: openingMinor,
      includeInTotals: includeInTotals,
      archived: archived,
      updatedAt: Clock.now().millisecondsSinceEpoch,
      hlc: hlc,
    );
    _db.mutateAccountWithOplog(row, _op(row, hlc), delete: false);
    return row;
  }

  /// 封存／取消封存（FR-A2；保留歷史交易語意）。
  AccountRow archive(String id, {bool archived = true}) =>
      update(id, archived: archived);

  /// 刪除帳戶（FR-A2 把關）：**信用卡未繳 > 0 → 拋
  /// [AccountInUseException]（提示改為封存）**；否則實體刪除＋oplog。
  /// 刪除帳戶＋**連動軟刪其相關交易**（PM 2026-11-19：孤兒交易會讓
  /// 明細/統計加總錯誤）。交易走墓標（「最近刪除」可還原；同步安全——
  /// 與 DeleteTransactionUseCase 同一語意）。回傳連動刪除筆數。
  int delete(String id) {
    final row = _find(id);
    if (row.type == 'credit') {
      final unpaid = calc.creditUnpaidTotal(
        card: accountEntity(row),
        txs: _db.allTransactions().map(txEntity).toList(),
      );
      if (unpaid > 0) {
        throw const AccountInUseException('此帳戶仍有未結算交易，可改為封存');
      }
    }
    final hlc = Hlc.now(deviceId).toString();
    _db.mutateAccountWithOplog(row, _op(row, hlc), delete: true);
    return _softDeleteRelatedTransactions(id);
  }

  /// 軟刪除某帳戶相關之全部未刪交易（來源或轉入目標）。
  int _softDeleteRelatedTransactions(String accountId) {
    final rows = _db.select(
      'SELECT id FROM transactions '
      'WHERE deleted_at IS NULL AND (account_id = ? OR to_account_id = ?)',
      [accountId, accountId],
    );
    var n = 0;
    for (final r in rows) {
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
      n++;
    }
    return n;
  }

  List<AccountRow> all() => _db.allAccounts();

  /// 計入合併統計之活躍帳戶（FR-A6：`includeInTotals && !archived`）。
  List<AccountRow> includedInTotals() => _db
      .allAccounts()
      .where((a) => a.includeInTotals && !a.archived)
      .toList();

  AccountRow _find(String id) {
    for (final a in _db.allAccounts()) {
      if (a.id == id) return a;
    }
    throw AccountInUseException('帳戶不存在：$id');
  }

  OplogRow _op(AccountRow row, String hlc) => OplogRow(
        entity: 'accounts',
        entityId: row.id,
        hlc: hlc,
        payload: jsonEncode(row.toSnapshot()),
        packedSeq: null,
      );
}
