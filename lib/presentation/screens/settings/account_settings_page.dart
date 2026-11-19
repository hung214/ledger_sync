import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/accounts/account_service.dart';
import '../../../application/providers.dart';
import '../../../domain/services/balance_calculator.dart';
import '../../theme/app_theme.dart';

/// 帳戶管理頁（SPEC FR-A7；SDD §8 設定群）：
/// 列表（名稱/類型/餘額/是否計入合併）→ 新增／編輯／刪除／封存。
///
/// 測試 keys（dsl §4.5）：acct-add／acct-name／acct-type／acct-opening／
/// acct-include-totals／acct-row-{name}／acct-edit-{name}／acct-delete-{name}。
class AccountSettingsPage extends ConsumerStatefulWidget {
  const AccountSettingsPage({super.key});

  @override
  ConsumerState<AccountSettingsPage> createState() =>
      _AccountSettingsPageState();
}

class _AccountSettingsPageState extends ConsumerState<AccountSettingsPage> {
  String? _message;
  late final AccountService _service = AccountService(ref.read(dbProvider));

  void _refresh() {
    // PM 2026-11-19 修復：新帳戶在總覽/快記不出現——activeAccountsProvider
    // 是「讀 db 快取」型 provider，mutation 後必須 invalidate（同分類集慣例）。
    ref.invalidate(activeAccountsProvider);
    ref.refreshAllData(); // 全畫面刷新（PM 2026-11-19）
    setState(() {});
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    setState(() => _message = msg);
  }

  Future<void> _openForm({String? editId}) async {
    final db = ref.read(dbProvider);
    final existing = editId == null
        ? null
        : db.allAccounts().firstWhere((a) => a.id == editId);
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final openingCtrl = TextEditingController(
        text: existing == null
            ? ''
            : NumberFormat('#,###').format(existing.openingAmountMinor));
    var type = existing?.type ?? 'cash';
    var includeInTotals = existing?.includeInTotals ?? true;
    var archived = existing?.archived ?? false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, 16 + MediaQuery.of(sheetCtx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(existing == null ? '新增帳戶' : '編輯帳戶',
                  style: Theme.of(sheetCtx).textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                key: const Key('acct-name'),
                controller: nameCtrl,
                decoration: const InputDecoration(
                    labelText: '帳戶名稱', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('acct-type'),
                initialValue: type,
                decoration: const InputDecoration(
                    labelText: '帳戶類型', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'cash', child: Text('現金')),
                  DropdownMenuItem(value: 'bank', child: Text('銀行')),
                  DropdownMenuItem(value: 'credit', child: Text('信用卡')),
                  DropdownMenuItem(value: 'ewallet', child: Text('電子支付／票證')),
                  DropdownMenuItem(value: 'other', child: Text('其他')),
                ],
                onChanged: (v) => setSheet(() => type = v ?? 'cash'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('acct-opening'),
                controller: openingCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: '期初餘額', border: OutlineInputBorder()),
              ),
              SwitchListTile(
                key: const Key('acct-include-totals'),
                title: const Text('計入合併統計（資產/負債/淨值）'),
                value: includeInTotals,
                onChanged: (v) => setSheet(() => includeInTotals = v),
              ),
              if (existing != null)
                SwitchListTile(
                  title: const Text('封存（自活躍列表隱藏，歷史保留）'),
                  value: archived,
                  onChanged: (v) => setSheet(() => archived = v),
                ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(sheetCtx).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('acct-save'),
                    onPressed: () {
                      final name = nameCtrl.text.trim();
                      if (name.isEmpty) return;
                      final opening = int.tryParse(
                              openingCtrl.text.replaceAll(',', '')) ??
                          0;
                      try {
                        if (existing == null) {
                          _service.create(
                              type: type,
                              name: name,
                              openingMinor: opening,
                              includeInTotals: includeInTotals);
                        } else {
                          _service.update(
                            editId!,
                            name: name,
                            type: type,
                            openingMinor: opening,
                            includeInTotals: includeInTotals,
                            archived: archived,
                          );
                        }
                        Navigator.of(sheetCtx).pop();
                        _refresh();
                      } catch (e) {
                        Navigator.of(sheetCtx).pop();
                        _showSnack('$e');
                      }
                    },
                    child: const Text('儲存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _delete(String id, String name) async {
    final db = ref.read(dbProvider);
    final txCount = db.select(
            'SELECT COUNT(*) c FROM transactions '
            "WHERE deleted_at IS NULL AND (account_id = ? OR to_account_id = ?)",
            [id, id])
        .first['c'] as int;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('刪除「$name」？'),
        content: Text(txCount == 0
            ? '此帳戶沒有交易。刪除後無法從帳戶列表復原（可重新新增）。'
            : '將**同時刪除此帳戶相關的 $txCount 筆交易**'
                '（可在「設定→最近刪除」還原；雲端同步會一併生效）。'),
        actions: [
          TextButton(
            key: const Key('acct-delete-cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('acct-delete-confirm'),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final n = _service.delete(id);
      _refresh();
      if (mounted && n > 0) _showSnack('已刪除帳戶＋$n 筆相關交易');
    } catch (e) {
      _showSnack('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.read(dbProvider);
    final accounts = db.allAccounts();
    final txs = db.allTransactions().map(txEntity).toList();
    const calc = BalanceCalculator();
    final fmt = NumberFormat('#,###');
    final tokens = AppTokens.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('帳戶管理')),
      floatingActionButton: FloatingActionButton(
        key: const Key('acct-add'),
        tooltip: '新增帳戶',
        onPressed: () => _openForm(),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          if (_message != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_message!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final a in accounts)
                  Card(
                    child: ListTile(
                      key: Key('acct-row-${a.name}'),
                      leading: Icon(switch (a.type) {
                        'cash' => Icons.payments_outlined,
                        'bank' => Icons.account_balance_outlined,
                        'credit' => Icons.credit_card,
                        'ewallet' => Icons.contactless_outlined,
                        _ => Icons.account_balance_wallet_outlined,
                      }),
                      title: Text(a.name),
                      subtitle: Text(
                        '${_typeLabel(a.type)}'
                        ' · 餘額 ${fmt.format(calc.assetBalance(account: accountEntity(a), txs: txs))}'
                        '${a.archived ? ' · 已封存' : ''}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!a.includeInTotals)
                            Container(
                              key: const Key('acct-excluded-badge'),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: tokens.subText.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('不計入合併',
                                  style: TextStyle(
                                      fontSize: 11, color: tokens.subText)),
                            ),
                          IconButton(
                            key: Key('acct-edit-${a.name}'),
                            tooltip: '編輯',
                            onPressed: () => _openForm(editId: a.id),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            key: Key('acct-delete-${a.name}'),
                            tooltip: '刪除',
                            onPressed: () => _delete(a.id, a.name),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 72),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _typeLabel(String type) => switch (type) {
        'cash' => '現金',
        'bank' => '銀行',
        'credit' => '信用卡',
        'ewallet' => '電子支付／票證',
        _ => '其他',
      };
}
