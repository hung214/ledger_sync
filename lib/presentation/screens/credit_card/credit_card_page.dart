import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/credit_card/billing_cycle_service.dart';
import '../../../application/providers.dart';
import '../../../core/clock.dart';
import '../../../data/sqlite/app_database.dart';
import '../../../domain/entities/account.dart';
import '../../../domain/services/balance_calculator.dart';
import '../../theme/app_theme.dart';
import 'card_settings_page.dart';

/// 信用卡頁（FR-C1/C3/C4/C6 呈現面；M3）。
///
/// - 開頁即觸發結帳檢查（FR-C3 sync 點：App 啟動/進頁面）。
/// - 頁首徽章：已繳（paid）／部分繳（partial）／**逾期**（due 已過且未繳清，
///   FR-C6；附「v1 不計息」註記）。
/// - 本期帳單卡：應繳（千分位）＋繳款日（M/D）＋繳款按鈕（全額/自訂金額）。
/// - 入口：總覽頁信用卡卡片點擊。
class CreditCardPage extends ConsumerStatefulWidget {
  const CreditCardPage({super.key, required this.cardAccountId});

  final String cardAccountId;

  @override
  ConsumerState<CreditCardPage> createState() => _CreditCardPageState();
}

class _CreditCardPageState extends ConsumerState<CreditCardPage> {
  @override
  void initState() {
    super.initState();
    // 結帳檢查（FR-C3 sync 點②：進頁面即結算已關閉週期；冪等）。
    // 必須於 build 完成後執行——build 期間 invalidate 會觸發
    // 「setState() called during build」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _runBillingOnce();
    });
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    ref.watch(ledgerProvider); // 交易變化即時刷新
    final card = db.allAccounts().firstWhere((a) => a.id == widget.cardAccountId);
    final statement = _latestStatement(db, widget.cardAccountId);
    final details = db.creditCardDetail(widget.cardAccountId);
    final cardStatements = db
        .allStatementsForTest()
        .where((s) => s.accountId == widget.cardAccountId)
        .toList()
      ..sort((a, b) => b.statementDate.compareTo(a.statementDate));
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // 未來已承諾（分期；FR-C7）：未來 pending 分期扣款合計＋剩餘期數。
    final futureRows = db
        .select('SELECT amount_minor, occurred_at, split_group_id '
            'FROM transactions WHERE account_id = ? '
            'AND installment_seq IS NOT NULL AND occurred_at > ? '
            "AND deleted_at IS NULL ORDER BY occurred_at", [
      widget.cardAccountId,
      nowMs,
    ]);
    final futureTotal = futureRows.fold<int>(0, (s, r) => s + (r['amount_minor'] as int));
    final calc = const BalanceCalculator();
    final account = _accountEntity(card);
    final openBalance =
        calc.creditOpenBalance(card: account, txs: db.allTransactions().map(txEntity));
    final fmt = NumberFormat('#,###');

    // 徽章判定（FR-C6：逾期 = due 已過且未繳清）。
    String? badge;
    if (statement != null) {
      final due = DateTime.fromMillisecondsSinceEpoch(statement.dueDate);
      final now = Clock.now();
      final overdue = now.isAfter(due) && statement.status != 'paid';
      if (overdue) {
        badge = '逾期';
      } else if (statement.status == 'paid') {
        badge = '已繳';
      } else if (statement.status == 'partial') {
        badge = '部分繳';
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(card.name),
        actions: [
          IconButton(
            key: const Key('card-settings-entry'),
            tooltip: '卡片設定',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CardSettingsPage(cardAccountId: widget.cardAccountId),
              ),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (badge != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                _Badge(
                  label: badge,
                  color: badge == '逾期'
                      ? AppTokens.of(context).danger
                      : (badge == '已繳'
                          ? AppTokens.of(context).success
                          : AppTokens.of(context).warning),
                ),
                if (badge == '逾期')
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text('v1 不計息',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppTokens.of(context).subText)),
                  ),
              ]),
            ),
          if (details?.last4 != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Icon(Icons.credit_card,
                    size: 16, color: AppTokens.of(context).subText),
                const SizedBox(width: 6),
                Text('•••• •••• •••• ${details!.last4}',
                    style: TextStyle(
                        fontSize: 13,
                        color: AppTokens.of(context).subText,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (statement != null) ...[
                    Text(
                      '本期帳單 ${fmt.format(statement.totalMinor)}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '繳款日 ${_md(statement.dueDate)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (statement.paidMinor > 0) ...[
                      const SizedBox(height: 4),
                      Text('已繳 ${fmt.format(statement.paidMinor)}'),
                    ],
                    if (statement.remainingMinor > 0) ...[
                      const SizedBox(height: 4),
                      Text('剩餘 ${fmt.format(statement.remainingMinor)}'),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        key: const Key('repay-button'),
                        onPressed: statement.status == 'paid'
                            ? null
                            : () => _showRepayDialog(context, statement),
                        child: const Text('繳款'),
                      ),
                    ),
                  ] else ...[
                    Text('本期應付 ${fmt.format(openBalance)}',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text('尚未產生帳單（結帳日後自動結算）'),
                  ],
                ],
              ),
            ),
          ),
          if (futureTotal > 0)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('未來已承諾（分期）',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(fmt.format(futureTotal),
                        style: Theme.of(context).textTheme.headlineSmall),
                    Text('${futureRows.length} 筆待扣（FR-C7：分期自動排程）',
                        style: TextStyle(
                            fontSize: 12, color: AppTokens.of(context).subText)),
                  ],
                ),
              ),
            ),
          if (cardStatements.length > 1)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('帳單歷史',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final st in cardStatements.skip(1))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(children: [
                          _Badge(
                            label: _historyBadge(st, nowMs),
                            color: _historyBadgeColor(st, nowMs, context),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${_md(st.periodStart)}~${_md(st.periodEnd)} 期',
                                    style: Theme.of(context).textTheme.bodyMedium),
                                Text(
                                    '應繳 ${fmt.format(st.totalMinor)} · 已繳 ${fmt.format(st.paidMinor)}'
                                    '${st.remainingMinor > 0 ? ' · 剩餘 ${fmt.format(st.remainingMinor)}' : ''}'
                                    ' · ${_md(st.dueDate)} 繳款截止',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: AppTokens.of(context).subText)),
                              ],
                            ),
                          ),
                        ]),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 歷史帳單徽章（F16/U1：部分繳/已繳/逾期；本期除外）。
  String _historyBadge(StatementRow st, int nowMs) {
    if (st.status == 'paid') return '已繳';
    if (st.remainingMinor > 0 &&
        DateTime.now().isAfter(DateTime.fromMillisecondsSinceEpoch(st.dueDate))) {
      return '逾期';
    }
    if (st.paidMinor > 0) return '部分繳';
    return '未繳';
  }

  Color _historyBadgeColor(StatementRow st, int nowMs, BuildContext context) {
    final badge = _historyBadge(st, nowMs);
    return badge == '逾期'
        ? AppTokens.of(context).danger
        : (badge == '已繳'
            ? AppTokens.of(context).success
            : AppTokens.of(context).warning);
  }

  Account _accountEntity(AccountRow r) => Account(
        id: r.id,
        type: AccountType.values.byName(r.type),
        name: r.name,
        currency: r.currency,
        openingAmountMinor: r.openingAmountMinor,
        archived: r.archived,
      );

  void _runBillingOnce() {
    BillingCycleService(ref.read(dbProvider), ref.read(notificationProvider))
        .run(widget.cardAccountId);
    ref.invalidate(ledgerProvider);
    ref.refreshAllData();
  }

  StatementRow? _latestStatement(AppDatabase db, String accountId) {
    final rows = db
        .allStatementsForTest()
        .where((s) => s.accountId == accountId)
        .toList()
      ..sort((a, b) => b.statementDate.compareTo(a.statementDate));
    return rows.isEmpty ? null : rows.first;
  }

  void _showRepayDialog(BuildContext context, StatementRow statement) {
    final controller = TextEditingController();
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                key: const Key('repay-full'),
                onPressed: () {
                  ref.read(repayStatementProvider).execute(
                        statementId: statement.id,
                        amountMinor: statement.totalMinor - statement.paidMinor,
                      );
                  ref.invalidate(ledgerProvider);
    ref.refreshAllData();
                  Navigator.of(sheetCtx).pop();
                  setState(() {});
                },
                child: const Text('全額繳款'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('repay-amount'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '自訂金額'),
                controller: controller,
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(
                key: const Key('repay-confirm'),
                onPressed: () {
                  // 金額輸入容許千分位（F04-FE S3：輸入 2,000）。
                  final amount =
                      int.tryParse(controller.text.replaceAll(',', '')) ?? 0;
                  if (amount > 0) {
                    ref.read(repayStatementProvider).execute(
                          statementId: statement.id,
                          amountMinor: amount,
                        );
                    ref.invalidate(ledgerProvider);
    ref.refreshAllData();
                  }
                  Navigator.of(sheetCtx).pop();
                  setState(() {});
                },
                child: const Text('確認'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _md(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}/${d.day}';
  }
}

/// 徽章（已繳/部分繳/逾期）。
class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('badge-$label'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}
