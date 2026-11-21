import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/recurring/recurring_service.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/core/hlc.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/presentation/app_shell.dart';
import 'package:ledger_sync/presentation/screens/ledger/ledger_page.dart';
import 'package:ledger_sync/presentation/screens/recurring/recurring_queue_page.dart';

import '../../test/helpers/db_fixture.dart';
import '../../test/helpers/gherkin/gherkin.dart';

/// F06-FE 情境執行器（@FE @M6 @FR-T5，4 情境：待確認 badge 與清單/
/// 確認入帳（可改金額）/本次跳過/逾期 3 次暫停標示）。
///
/// 來源：specs/plan/tests/frontend/F06_recurring-transactions.feature（rootBundle）。
/// 句型登記簿：specs/plan/tests/dsl.md §3（v1.1）。
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final doc = GherkinParser.parse(await rootBundle
      .loadString('integration_test/features/F06_recurring-transactions.feature'));

  testWidgets('F06-FE：定期交易 UI（4 情境）', (tester) async {
    final w = _World(tester);
    final runner = GherkinRunner();
    _bind(runner, w);
    try {
      final executed = await runner.run(doc, tagFilter: (tags) => tags.contains('@FE'));
      expect(executed, 4, reason: 'F06-FE 應執行 4 個情境');
      // ignore: avoid_print
      print(runner.log.join('\n'));
    } finally {
      Clock.unfreeze();
      for (final db in w.dbs) {
        db.close();
      }
      for (final c in w.containers) {
        c.dispose();
      }
    }
  });
}

class _World {
  _World(this.tester);

  final WidgetTester tester;
  final List<AppDatabase> dbs = [];
  final List<ProviderContainer> containers = [];
  AppDatabase? db;
  ProviderContainer? container;
  bool pumped = false;
  final accounts = <String, String>{};
  final categories = <String, String>{};
  final recurringIds = <String, String>{};
}

void _bind(GherkinRunner runner, _World w) {
  // ── Background ───────────────────────────────────────────
  runner.on(r'App 已完成首次設定$', (p) {
    final db = DbFixture.create();
    w.dbs.add(db);
    w.db = db;
    w.pumped = false;
    w.accounts.clear();
    w.categories.clear();
    w.recurringIds.clear();
  });

  runner.on(r'已建立帳戶「{name}」\(餘額 {amount}\)$', (p) async {
    final id = 'a-${w.accounts.length}';
    await DbFixture.seedAccount(
      w.db!,
      id: id,
      type: 'bank',
      name: p['name']!,
      opening: _amount(p['amount']!),
    );
    w.accounts[p['name']!] = id;
  });

  runner.on(r'已建立定期交易「{name}」每月 {day} 日金額 {amt}（提醒確認制）$', (p) {
    final id = 'r-${w.recurringIds.length}';
    final anchor = DateTime(2026, 6, int.parse(p['day']!), 9);
    final now = Clock.now().millisecondsSinceEpoch;
    final row = RecurringRow(
      id: id,
      name: p['name']!,
      kind: 'expense',
      amountMinor: _amount(p['amt']!),
      accountId: w.accounts.values.first,
      categoryId: w.categories.values.firstOrNull ?? 'c-default',
      frequency: 'monthly',
      anchorDate: anchor.millisecondsSinceEpoch,
      endType: 'never',
      nextDueDate: anchor.millisecondsSinceEpoch,
      reminderCount: 0,
      paused: false,
      createdAt: now,
      updatedAt: now,
      hlc: Hlc(now, 0, 'd-local').toString(),
    );
    w.db!.insertRecurringWithOplog(
        row,
        OplogRow(
          entity: 'recurring_transactions',
          entityId: id,
          hlc: row.hlc,
          payload: jsonEncode(row.toSnapshot()),
          packedSeq: null,
        ));
    w.recurringIds[p['name']!] = id;
  });

  runner.on(r'模擬系統時間為 {dt}$', (p) async {
    // 2026/06/01（無時刻）→ 09:00（種資 anchor 對齊—— Background 語意）。
    final d = _dateTime(p['dt']!);
    Clock.freeze(DateTime(d.year, d.month, d.day, 9));
  });

  // ── When ─────────────────────────────────────────────────
  runner.on(r'開啟明細頁$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-明細')));
    await w.tester.pumpAndSettle();
    expect(w.tester.any(find.byType(LedgerPage)), isTrue, reason: '明細頁應作用中');
  });

  runner.on(r'按下 badge$', (p) async {
    await w.tester.tap(find.byKey(const Key('recurring-badge')));
    await w.tester.pumpAndSettle();
    expect(w.tester.any(find.byType(RecurringQueuePage)), isTrue,
        reason: '待確認清單應已開啟');
  });

  runner.on(r'待確認清單含「{name} {amt}」$', (p) async {
    // 前置語意＝清單呈現（啟動檢查已產生佇列）——主動開頁（跨情境殘樹防護）。
    await _ensureApp(w);
    await _openQueue(w);
    final r = w.db!.recurringById(w.recurringIds[p['name']!]!);
    expect(r, isNotNull, reason: '佇列應含到期排程');
  });

  runner.on(r'將金額改為 {amt} 並按下「確認入帳」$', (p) async {
    final r = w.db!.recurringById(w.recurringIds.values.first)!;
    final amountKey = Key('recurring-amount-${r.id}');
    final confirmKey = Key('confirm-recurring-${r.id}');
    // ignore: avoid_print
    print('DEBUG confirm: id=${r.id} amountKey=${w.tester.any(find.byKey(amountKey))} '
        'confirmKey=${w.tester.any(find.byKey(confirmKey))}');
    await w.tester.enterText(find.byKey(amountKey), p['amt']!.replaceAll(',', ''));
    await w.tester.pump();
    await w.tester.tap(find.byKey(confirmKey));
    await w.tester.pumpAndSettle();
    // ignore: avoid_print
    print('DEBUG confirm: txs=${w.db!.allTransactions().length}');
  });

  runner.on(r'按下「本次跳過」$', (p) async {
    final r = w.db!.recurringById(w.recurringIds.values.first)!;
    await w.tester.tap(find.byKey(Key('skip-recurring-${r.id}')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'房租連續 3 次開啟 App 皆未處理（{dates}）$', (p) async {
    // 逐日凍結＋重啟（新 container——啟動檢查累計 reminder_count）。
    // feature 日期為短格式「6/1、6/2、6/3」——年取凍結基準（Clock.now 之年）。
    final base = Clock.now();
    final days = RegExp(r'(\d{1,2})/(\d{1,2})')
        .allMatches(p['dates']!)
        .map((m) => DateTime(
            base.year, int.parse(m.group(1)!), int.parse(m.group(2)!), 9))
        .toList();
    for (final day in days) {
      Clock.freeze(day);
      w.pumped = false;
      await _ensureApp(w);
      await w.tester.pumpAndSettle();
    }
  });

  runner.on(r'開啟待確認清單$', (p) async {
    await _ensureApp(w);
    await _openQueue(w);
  });

  // ── Then ─────────────────────────────────────────────────
  runner.on(r'顯示「待確認 {n}」badge$', (p) {
    expect(w.tester.any(find.text('待確認 ${p['n']!}')), isTrue,
        reason: 'FR-T5：到期未確認 badge');
  });

  runner.on(r'顯示「待確認清單」含「{name} {amt}」$', (p) {
    expect(w.tester.any(find.byType(RecurringQueuePage)), isTrue);
    expect(w.tester.any(find.text(p['name']!)), isTrue, reason: '排程名稱');
    expect(w.tester.any(find.text(p['amt']!.replaceAll(',', ''))), isTrue,
        reason: '模板金額（可編輯欄初值）');
  });

  runner.on(r'明細頁即時顯示該 {n} 筆$', (p) async {
    // 清單→返回主殼→明細。
    final navigator = w.tester.state<NavigatorState>(find.byType(Navigator).first);
    while (navigator.canPop()) {
      await navigator.maybePop();
      await w.tester.pumpAndSettle();
    }
    await w.tester.tap(find.byKey(const Key('nav-明細')));
    await w.tester.pumpAndSettle();
    final n = int.parse(p['n']!);
    if (n > 0) {
      final txs = w.db!.allTransactions().where((t) => t.deletedAt == null);
      expect(txs.length, n, reason: 'AC-12：確認入帳後明細即時');
    } else {
      expect(w.db!.allTransactions().where((t) => t.deletedAt == null), isEmpty,
          reason: '跳過不入帳');
    }
  });

  runner.on(r'顯示「下期 {date} 提醒」$', (p) async {
    // 「下期 M/d 提醒」呈現於待確認清單項——斷言前確保頁面開啟。
    if (w.tester.any(find.byType(RecurringQueuePage)) != true) {
      await _openQueue(w);
    }
    expect(w.tester.any(find.text('下期 ${p['date']!} 提醒', skipOffstage: false)),
        isTrue, reason: 'FR-T5：下期推進呈現');
  });

  runner.on(r'顯示「已暫停提醒」$', (p) {
    expect(
        w.tester.any(find.text('已暫停提醒', skipOffstage: false)), isTrue,
        reason: 'FR-T5：逾期 3 次標示');
  });

  runner.on(r'顯示「{text}」$', (p) {
    expect(w.tester.any(find.text(p['text']!, skipOffstage: false)), isTrue,
        reason: '應顯示「${p['text']}」');
  });
}

// ── 輔助 ─────────────────────────────────────────────

Future<void> _ensureApp(_World w) async {
  if (w.pumped) return;
  final container = ProviderContainer(overrides: [
    dbProvider.overrideWithValue(w.db!),
  ]);
  w.containers.add(container);
  w.container = container;
  await w.tester.pumpWidget(
    KeyedSubtree(
      key: ValueKey('app-shell-${w.containers.length}'),
      child: UncontrolledProviderScope(container: container, child: const AppShell()),
    ),
  );
  await w.tester.pumpAndSettle();
  w.pumped = true;
  // FR-T5 啟動檢查（與 MainShellPage 啟動鉤子同語意——明確呼叫保時序確定）。
  RecurringService(w.db!, container.read(notificationProvider)).runCheck();
  await w.tester.pumpAndSettle();
}

Future<void> _openQueue(_World w) async {
  if (w.tester.any(find.byKey(const Key('recurring-badge'))) != true) {
    await w.tester.tap(find.byKey(const Key('nav-明細')));
    await w.tester.pumpAndSettle();
  }
  await w.tester.tap(find.byKey(const Key('recurring-badge')));
  await w.tester.pumpAndSettle();
}

DateTime _dateTime(String s) {
  final m = RegExp(r'^(\d{4})/(\d{2})/(\d{2})(?: (\d{1,2}):(\d{2}))?$')
      .firstMatch(s.trim());
  if (m == null) throw FormatException('日期時間格式未支援：$s（dsl.md §1-3）');
  return DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    m.group(4) == null ? 0 : int.parse(m.group(4)!),
    m.group(5) == null ? 0 : int.parse(m.group(5)!),
  );
}

int _amount(String s) {
  final m = RegExp(r'^-?[\d,]+').firstMatch(s.trim());
  if (m == null) throw FormatException('金額格式未支援：$s');
  return int.parse(m.group(0)!.replaceAll(',', ''));
}
