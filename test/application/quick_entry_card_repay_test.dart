import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/domain/entities/account.dart';
import 'package:ledger_sync/domain/entities/transaction.dart';
import 'package:ledger_sync/domain/services/balance_calculator.dart';
import 'package:ledger_sync/presentation/screens/quick_entry/quick_entry_controller.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// T77（PM 2026-11-24）：**快記繳卡費**——第四模式（有信用卡帳戶才顯示）。
/// 金額預設＝未繳合計（creditUnpaidTotal）；儲存走 RepayStatementUseCase：
/// 有未繳清帳單→帳單 paid 累加；無帳單→純 repayment 交易（仍抵扣未繳）。
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    Clock.freeze(DateTime(2026, 11, 24, 12));
    db = DbFixture.create();
    DbFixture.seedAccount(db, id: 'a-cash', type: 'cash', name: '現金');
    DbFixture.seedAccount(db, id: 'a-card', type: 'credit', name: '示例卡');
    // 刷卡 500（預扣 pending）＝待繳額度。
    DbFixture.seedTx(db,
        id: 't-pend',
        kind: 'expense',
        amountMinor: 500,
        accountId: 'a-card',
        settlementStatus: 'pending',
        occurredAt: Clock.now().millisecondsSinceEpoch);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-t')),
    ]);
    addTearDown(() {
      Clock.unfreeze();
      container.dispose();
      db.close();
    });
  });

  QuickEntryController ctrl() =>
      container.read(quickEntryControllerProvider.notifier);

  List<Tx> allTxs() => db.allTransactions().map(txEntity).toList();

  int repaymentCount() => allTxs().where((t) => t.kind == TxKind.repayment).length;

  test('切繳卡費模式 → 金額帶入未繳合計 500＋卡片/扣款帳戶自動選', () {
    ctrl().setMode(QuickEntryMode.repay);
    final state = container.read(quickEntryControllerProvider);
    expect(state.amount, '500', reason: '金額預設＝未繳合計');
    expect(state.toAccount?.id, 'a-card', reason: '目標＝卡片');
    expect(state.account?.id, 'a-cash', reason: '扣款帳戶＝linked ?: 首個非信用卡');
  });

  test('儲存（無帳單）→ repayment 交易產生＋未繳合計歸 0', () {
    ctrl().setMode(QuickEntryMode.repay);
    container.read(quickEntryControllerProvider.notifier).save();

    expect(repaymentCount(), 1, reason: 'kind=repayment 交易');
    final rep = allTxs().firstWhere((t) => t.kind == TxKind.repayment);
    expect(rep.accountId, 'a-cash', reason: '從扣款帳戶轉出');
    expect(rep.toAccountId, 'a-card', reason: '繳入卡片');
    expect(rep.amountMinor, 500);
    // 未繳合計＝本期應付(500) − 還款(500) = 0。
    final card = db.allAccounts().firstWhere((a) => a.id == 'a-card');
    final calc = const BalanceCalculator();
    final txs = allTxs();
    expect(
        calc.creditUnpaidTotal(
            card: Account(
              id: card.id,
              type: AccountType.values.byName(card.type),
              name: card.name,
              currency: card.currency,
              openingAmountMinor: card.openingAmountMinor,
              archived: card.archived,
            ),
            txs: txs),
        0);
  });

  test('儲存（有未繳清帳單）→ 帳單 paid 累加、狀態流轉 partial/paid', () async {
    final stId = await DbFixture.seedStatement(db,
        accountId: 'a-card',
        periodStartMs: Clock.now().millisecondsSinceEpoch - 86400000 * 20,
        periodEndMs: Clock.now().millisecondsSinceEpoch - 86400000,
        totalMinor: 1000);
    ctrl().setMode(QuickEntryMode.repay); // 帶入未繳合計＝500（待繳消費）＋帳單?
    // 注意：未繳合計＝消費 500（open）−還款 0＝500（帳單語意另行）；
    // 繳 600 → 帳單 paid 600 < 1000 = partial。
    ctrl().setAmount('600');
    container.read(quickEntryControllerProvider.notifier).save();

    final st = db.statementById(stId)!;
    expect(st.paidMinor, 600, reason: '帳單 paid 累加');
    expect(st.status, 'partial');
    expect(repaymentCount(), 1);

    // 再繳 400 → 繳清 paid。
    ctrl().setMode(QuickEntryMode.repay);
    ctrl().setAmount('400');
    container.read(quickEntryControllerProvider.notifier).save();
    final st2 = db.statementById(stId)!;
    expect(st2.paidMinor, 1000);
    expect(st2.status, 'paid', reason: 'paid ≥ total → paid（取消 N-5）');
    expect(st2.paidAt, isNotNull);
  });
}
