import 'dart:math';

import '../entities/account.dart';
import '../entities/transaction.dart';
import '../../core/money.dart';

/// 餘額計算器（SDD §4.3）。
///
/// **原則 2（衍生餘額）**：任何餘額不儲存，一律由交易即時重算——
/// 這是同步 LWW 衝突不破壞帳務守恆的根基（SDD §5.5.4）。
///
/// 資產帳戶（cash/bank/ewallet/other）：
/// ```
/// 餘額 = opening
///      + Σ income(account)
///      + Σ transfer.in(to_account)
///      - Σ expense(account)
///      - Σ transfer.out(account)
///      - Σ repayment.out(account)   // 信用卡還款轉出
/// ```
/// 信用卡（credit）：顯示「本期應付」與「未繳帳單」，屬負債語意，不適用本公式。
class BalanceCalculator {
  const BalanceCalculator();

  /// 計算資產帳戶餘額（minor units，**帳戶本位幣**）。[txs] 需為該帳戶相關之
  /// 全部交易；外幣交易依 [Tx.fxRate] 換算為帳戶幣別（FR-T4，整數運算）。
  int assetBalance({
    required Account account,
    required Iterable<Tx> txs,
  }) {
    var balance = account.openingAmountMinor;
    for (final tx in txs) {
      if (tx.deleted) continue; // 墓標排除
      final amount = _toAccountCurrency(tx, account);
      switch (tx.kind) {
        case TxKind.income:
          if (tx.accountId == account.id) balance += amount;
        case TxKind.expense:
          if (tx.accountId == account.id) balance -= amount;
        case TxKind.transfer:
          if (tx.accountId == account.id) balance -= amount;
          if (tx.toAccountId == account.id) balance += amount;
        case TxKind.repayment:
          // 還款轉出（from = 扣款帳戶）；信用卡端屬負債面，不在此計算。
          if (tx.accountId == account.id) balance -= amount;
        case TxKind.refund:
          // 退款作用於信用卡（負債面），資產帳戶不計。
          break;
      }
    }
    return balance;
  }

  /// 外幣交易金額 → 帳戶幣別 minor units（FR-T4）。
  ///
  /// 同幣別原值；異幣別：`amountMinor × fxRate × 10^(toExp − fromExp)` 後
  /// 四捨五入（USD 10000 minor × 32 ÷ 100 = 3200 TWD）。無匯率 → 原幣面額
  /// （不猜測；匯率必填由 UseCase 驗證）。
  int _toAccountCurrency(Tx tx, Account account) {
    if (tx.currency == account.currency) return tx.amountMinor;
    final rate = tx.fxRate;
    if (rate == null) return tx.amountMinor;
    final fromExp = Money(0, currency: tx.currency).exponent;
    final toExp = Money(0, currency: account.currency).exponent;
    final converted = tx.amountMinor * rate * pow(10, toExp - fromExp);
    return converted.round();
  }

  /// 信用卡「本期應付」：Σ 預扣支出 − Σ 退款（M3 帳單引擎前之骨架版）。
  int creditOpenBalance({
    required Account card,
    required Iterable<Tx> txs,
  }) {
    var open = 0;
    for (final tx in txs) {
      if (tx.deleted || tx.accountId != card.id) continue;
      // PM 2026-11-19 修復：'none'（歷史資料/未知來源）視同未結帳——
      // 只排除已結入帳單/已繳（billed/settled），否則應付恆 0。
      if (tx.settlementStatus == SettlementStatus.billed ||
          tx.settlementStatus == SettlementStatus.settled) {
        continue;
      }
      switch (tx.kind) {
        case TxKind.expense:
          open += tx.amountMinor;
        case TxKind.refund:
          open -= tx.amountMinor;
        default:
          break;
      }
    }
    return open;
  }

  /// 信用卡「未繳合計」：本期應付 − Σ 還款抵扣（toAccountId 指向該卡者），下限 0。
  ///
  /// 還款使負債減少但**不得為負**（無負債時還款不產生負未繳；溢繳語意屬
  /// M3 帳單引擎，F04）。[txs] 需為該卡相關之全部交易（F02 S2.6）。
  int creditUnpaidTotal({
    required Account card,
    required Iterable<Tx> txs,
  }) {
    var repayments = 0;
    for (final tx in txs) {
      if (!tx.deleted && tx.kind == TxKind.repayment && tx.toAccountId == card.id) {
        repayments += tx.amountMinor;
      }
    }
    final open = creditOpenBalance(card: card, txs: txs) - repayments;
    return open < 0 ? 0 : open;
  }
}
