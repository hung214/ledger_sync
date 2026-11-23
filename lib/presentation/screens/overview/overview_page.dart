import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/budgets/budget_evaluator.dart';
import '../../../application/lock/lock_fe_state.dart';
import '../../../application/providers.dart';
import '../../../application/stats/monthly_stats_service.dart';
import '../../../application/accounts/totals_service.dart';
import '../../../core/version.dart';
import '../../../domain/entities/transaction.dart';
import '../../../domain/services/balance_calculator.dart';
import '../../theme/app_theme.dart';
import '../budget/budget_page.dart';
import '../credit_card/credit_card_page.dart';
import '../demo/demo_gallery_page.dart';
import '../scan/scan_page.dart';
import '../settings/settings_hub_page.dart';

/// 總覽頁（FR-R1；對照雛型 `specs/plan/ui/01-dashboard.html`）。
///
/// 版面：本月收支（支出/收入/結餘）→ 資產/負債/淨值 → 收入目標 →
/// 預算摘要 → 帳戶 → 最近交易（版本頁尾）。
/// **雙殼辨識**：寬螢幕（≥700px，桌面 Rail 殼）**雙欄**並排；窄螢幕（行動
/// 底部導覽殼）單欄堆疊——同一份元件、密度與欄數依寬度分流。
///
/// 相容性（FE 斷言紅線）：`privacy-toggle`／`scan-entry`／`app-settings`
/// key、帳戶列 `find.text('餘額 N')`（唯一）、帳戶名可點（f04 進信用卡）、
/// 遮蔽時**全部金額** `●●●●`。
class OverviewPage extends ConsumerWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(activeAccountsProvider);
    final txs = ref.watch(ledgerProvider).map(txEntity).toList();
    const calc = BalanceCalculator();
    final db = ref.watch(dbProvider);
    final evaluator = BudgetEvaluator(db);
    final goal = evaluator.incomeGoalStatus();
    final monthly = MonthlyStatsService(db);
    final masked = ref.watch(privacyMaskedProvider);
    final fmt = NumberFormat('#,###');
    final tokens = AppTokens.of(context);
    // FR-A6 合併計算：僅計入 includeInTotals && !archived（TotalsService）。
    final totals = TotalsService(db).compute();

    String money(int minor) => masked ? '●●●●' : fmt.format(minor);
    String signed(int minor, {required bool minus}) =>
        masked ? '●●●●' : '${minus ? '−' : '+'}${fmt.format(minor)}';

    final expense = monthly.expenseMinorThisMonth();
    final income = monthly.incomeMinorThisMonth();
    final asset = totals.assetsMinor;
    final liability = totals.liabilitiesMinor;
    final recent = [...txs]..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

    final now = DateTime.now();
    final primary = <Widget>[
      if (accounts.isEmpty)
        const _Section(
          child: Column(
            children: [
              Icon(Icons.account_balance_wallet_outlined, size: 36),
              SizedBox(height: 8),
              Text('尚無帳戶——建立帳戶後這裡會顯示餘額'),
            ],
          ),
        ),
      _Section(
        title: '本月收支（${now.month} 月）',
        child: Column(
          children: [
            // 標籤帶「本月」前綴——避免與明細語意斷言（F02「儲值不顯示『支出』」）
            // 之全域文字比對衝突（IndexedStack 會同時建入所有分頁）。
            _MoneyRow(label: '本月支出', value: signed(expense, minus: true), color: tokens.danger),
            const SizedBox(height: 6),
            _MoneyRow(label: '本月收入', value: signed(income, minus: false), color: tokens.success),
            const SizedBox(height: 6),
            _MoneyRow(label: '結餘', value: money(income - expense)),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(child: _StatCard(label: '資產', value: money(asset))),
          const SizedBox(width: 8),
          Expanded(
              child: _StatCard(
                  label: '負債（信用卡）', value: money(liability), danger: true)),
          const SizedBox(width: 8),
          Expanded(child: _StatCard(label: '淨值', value: money(asset - liability))),
        ],
      ),
      const SizedBox(height: 8),
      _Section(
        title: '收入目標',
        trailing: goal == null
            ? null
            : _Badge(goal.achieved ? '已達成 ${goal.ratePercent}%' : '進行中 ${goal.ratePercent}%'),
        child: goal == null
            ? Text('未設定——於預算頁設定後顯示進度',
                style: TextStyle(color: tokens.subText))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 單一 Text 保留「{已達成} / 目標 {目標}」精確格式
                  // （F05-FE 以 find.text 嚴格比對；勿拆成兩個 Text）。
                  Text('${money(goal.achievedMinor)} / 目標 ${money(goal.goalMinor)}',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: tokens.success)),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: goal.goalMinor <= 0
                          ? 0
                          : (goal.achievedMinor / goal.goalMinor).clamp(0.0, 1.0),
                      minHeight: 8,
                      color: tokens.success,
                      backgroundColor: tokens.track,
                    ),
                  ),
                ],
              ),
      ),
    ];

    final secondary = <Widget>[
      if (db.allBudgets().where((b) => b.categoryId != null).isNotEmpty)
        _Section(
          title: '預算摘要',
          child: Column(
            children: [
              for (final b in db.allBudgets())
                if (b.categoryId != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: BudgetProgressBar(
                      name: db.categoryName(b.categoryId!) ?? '分類預算',
                      usageMinor:
                          evaluator.categoryUsage(b.categoryId!)?.totalMinor ?? 0,
                      amountMinor: b.amountMinor,
                    ),
                  ),
            ],
          ),
        ),
      _Section(
        title: '帳戶',
        child: Column(
          children: [
            for (final row in accounts)
              ListTile(
                key: Key('account-${row.id}'),
                contentPadding: EdgeInsets.zero,
                onTap: row.type == 'credit'
                    ? () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => CreditCardPage(cardAccountId: row.id),
                        ))
                    : null,
                leading: Icon(_accountIcon(row.type)),
                title: Text(row.name),
                subtitle: row.type == 'credit'
                    ? const Text('點擊檢視帳單')
                    // FR-A2：不計入合併統計之帳戶標示（總覽合計已排除）。
                    : (!row.includeInTotals
                        ? const Text('不計入合併',
                            key: Key('acct-excluded-badge'))
                        : null),
                trailing: Text(
                  // F02-FE S2：餘額千分位；F08-FE S5：隱私遮蔽（●●●●）。
                  '餘額 ${money(calc.assetBalance(account: accountEntity(row), txs: txs))}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
          ],
        ),
      ),
      _Section(
        title: '最近交易',
        child: recent.isEmpty
            ? Text('尚無交易——點「+」快記第一筆',
                style: TextStyle(color: tokens.subText))
            : Column(
                children: [
                  for (final tx in recent.take(3)) ...[
                    _RecentTxRow(tx: tx, fmt: fmt, masked: masked),
                    if (tx != recent.take(3).last) const Divider(height: 1),
                  ],
                ],
              ),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('總覽'),
        actions: [
          // 隱私遮蔽開關（FR-X3；F08-FE S5）。
          IconButton(
            key: const Key('privacy-toggle'),
            tooltip: '遮蔽金額',
            onPressed: () => ref.read(privacyMaskedProvider.notifier).toggle(),
            icon: Icon(ref.watch(privacyMaskedProvider)
                ? Icons.visibility_off
                : Icons.visibility),
          ),
          // 掃描入口（FR-S6：獨立於快記大鈕；F03 S1）。
          IconButton(
            key: const Key('scan-entry'),
            tooltip: '掃描',
            onPressed: () => openScanFlow(context, ref),
            icon: const Icon(Icons.document_scanner_outlined),
          ),
          // 設定入口（M7 恢復——PM 2026-10-21 決策含雲端同步）。
          IconButton(
            key: const Key('app-settings'),
            tooltip: '設定',
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsHubPage())),
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: 'UI Demo（設計參考）',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DemoGalleryPage()),
            ),
            icon: const Icon(Icons.palette_outlined),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // 桌面板（Rail 殼／寬視窗）雙欄；行動版單欄堆疊（雙殼辨識）。
          final wide = constraints.maxWidth >= 700;
          final footer = Padding(
            padding: const EdgeInsets.only(top: 24, bottom: 8),
            child: Center(
              child: Text('LedgerSync v$appVersion',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          );
          if (!wide) {
            return ListView(
              padding: const EdgeInsets.all(12),
              children: [...primary, ...secondary, footer],
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Column(children: primary)),
                  const SizedBox(width: 16),
                  Expanded(child: Column(children: secondary)),
                ],
              ),
              footer,
            ],
          );
        },
      ),
    );
  }
}

/// 區塊卡（標題＋內容；對照雛型卡片樣式）。
class _Section extends StatelessWidget {
  const _Section({this.title, this.trailing, required this.child});

  final String? title;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(title!,
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: tokens.subText)),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 10),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class _MoneyRow extends StatelessWidget {
  const _MoneyRow({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: tokens.subText)),
        Text(value,
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: color ?? Theme.of(context).colorScheme.onSurface)),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, this.danger = false});

  final String label;
  final String value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: tokens.subText)),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: danger ? tokens.danger : Theme.of(context).colorScheme.onSurface)),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
          color: tokens.success.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10)),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, color: tokens.success, fontWeight: FontWeight.w600)),
    );
  }
}

class _RecentTxRow extends StatelessWidget {
  const _RecentTxRow({required this.tx, required this.fmt, required this.masked});

  final dynamic tx;
  final NumberFormat fmt;
  final bool masked;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final db = ProviderScope.containerOf(context).read(dbProvider);
    final hasAttachment = db.attachmentsForTransaction(tx.id).isNotEmpty;
    final isExpense = tx.kind == TxKind.expense;
    final amountText = masked
        ? '●●●●'
        : (isExpense ? '−' : '+') + fmt.format(tx.amountMinor);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.receipt_long_outlined),
      title: Text(tx.merchant ??
          (tx.categoryId == null ? null : db.categoryName(tx.categoryId)) ??
          '交易'),
      subtitle: Text(
        '${DateFormat('M/d HH:mm').format(DateTime.fromMillisecondsSinceEpoch(tx.occurredAt))}'
        '${hasAttachment ? ' · 📷' : ''}',
        style: TextStyle(fontSize: 12, color: tokens.subText),
      ),
      trailing: Text(amountText,
          style: TextStyle(
              fontWeight: FontWeight.w600,
              color: isExpense ? tokens.danger : tokens.success)),
    );
  }
}

/// 帳戶類型圖示（UI 打磨；AccountType 對映——一眼辨識帳戶性質）。
IconData _accountIcon(String type) => switch (type) {
      'cash' => Icons.payments_outlined,
      'bank' => Icons.account_balance_outlined,
      'credit' => Icons.credit_card,
      'ewallet' => Icons.contactless_outlined,
      _ => Icons.account_balance_wallet_outlined,
    };
