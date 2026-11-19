import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers.dart';
import '../../../application/recurring/recurring_service.dart';
import '../../../core/clock.dart';
import '../../../data/sqlite/app_database.dart';

/// 待確認清單（FR-T5/AC-12 呈現面）：到期未確認排程——金額可改＋確認入帳
/// ＋本次跳過；下期提醒顯示；逾期 3 次項標示「已暫停提醒」。
class RecurringQueuePage extends ConsumerStatefulWidget {
  const RecurringQueuePage({super.key});

  @override
  ConsumerState<RecurringQueuePage> createState() => _RecurringQueuePageState();
}

class _RecurringQueuePageState extends ConsumerState<RecurringQueuePage> {
  late RecurringService _service;
  final _amountCtrls = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _service = RecurringService(ref.read(dbProvider), ref.read(notificationProvider));
  }

  @override
  void dispose() {
    for (final c in _amountCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctrl(RecurringRow r) => _amountCtrls.putIfAbsent(
      r.id, () => TextEditingController(text: '${r.amountMinor}'));

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    // 全活躍排程：到期項（≤今天）帶確認/跳過操作；非到期項帶「下期 M/d 提醒」
    // 預告（FR-T5 呈現面——確認/跳過後推進到下期仍可見，F06-FE S2/S3 契約）。
    final rows = db.allRecurring();
    final endOfDay =
        DateTime(Clock.now().year, Clock.now().month, Clock.now().day + 1)
                .millisecondsSinceEpoch -
            1;
    return Scaffold(
      appBar: AppBar(title: const Text('待確認清單', key: Key('recurring-queue-title'))),
      body: rows.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.event_available_outlined,
                      size: 40, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 8),
                  const Text('目前沒有待確認項目'),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final r in rows)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(r.name,
                                  style: Theme.of(context).textTheme.titleMedium),
                              const Spacer(),
                              Text(_nextDueLabel(r)),
                            ],
                          ),
                          if (r.paused)
                            Text('已暫停提醒',
                                key: Key('paused-${r.id}'),
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.error)),
                          if (r.nextDueDate <= endOfDay) ...[
                            // 到期項：金額可改＋確認/跳過（AC-12）。
                            const SizedBox(height: 8),
                            TextField(
                              key: Key('recurring-amount-${r.id}'),
                              controller: _ctrl(r),
                              decoration:
                                  const InputDecoration(labelText: '金額（元）'),
                              keyboardType: TextInputType.number,
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                FilledButton(
                                  key: Key('confirm-recurring-${r.id}'),
                                  onPressed: () {
                                    final amount = int.tryParse(_ctrl(r).text
                                        .replaceAll(',', ''));
                                    if (amount == null || amount <= 0) return;
                                    _service.confirm(
                                      scheduleId: r.id,
                                      amountMinor: amount,
                                      date: DateTime(Clock.now().year,
                                          Clock.now().month, Clock.now().day),
                                    );
                                    ref.read(ledgerProvider.notifier).refresh();
                                    ref.refreshAllData();
                                    ref
                                        .read(recurringDueCountProvider.notifier)
                                        .refresh();
                                    setState(() {});
                                  },
                                  child: const Text('確認入帳'),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  key: Key('skip-recurring-${r.id}'),
                                  onPressed: () {
                                    _service.skip(scheduleId: r.id);
                                    ref
                                        .read(recurringDueCountProvider.notifier)
                                        .refresh();
                                    setState(() {});
                                  },
                                  child: const Text('本次跳過'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  String _nextDueLabel(RecurringRow r) {
    final due = DateTime.fromMillisecondsSinceEpoch(r.nextDueDate);
    return '下期 ${due.month}/${due.day} 提醒';
  }
}
