import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/presentation/app_shell.dart';

import '../../test/helpers/db_fixture.dart';
import '../../test/helpers/gherkin/gherkin.dart';

/// F05-FE 情境執行器（@FE @M2 @FR-B @P0，5 情境）。
///
/// 來源：specs/plan/tests/frontend/F05_budget-income-goal.feature（sync_features.ps1
/// 同步副本，pubspec 資產入包——桌面 App 行程 CWD 非專案根，須 rootBundle 讀）。
/// 句型登記簿：specs/plan/tests/dsl.md §3。綁定：T-H7 自製 runner（TR-9）＋
/// integration_test；背景每情境重建 App（in-memory DB 直寫）。
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final doc = GherkinParser.parse(
      await rootBundle.loadString('integration_test/features/F05_budget-income-goal.feature'));

  testWidgets('F05-FE：預算與收入目標 UI（5 情境：警示色／超支／預扣／達成／通知開關）',
      (tester) async {
    final w = _World(tester);
    final runner = GherkinRunner();
    _bind(runner, w);
    try {
      final executed = await runner.run(
        doc,
        tagFilter: (tags) => tags.contains('@FE') && !tags.contains('@P1'),
      );
      expect(executed, 5, reason: 'F05-FE 應執行 5 個情境（@FE @P0）');
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

/// 情境共享狀態（每 Scenario 由 Background 重置；dsl.md §1.5 Given 直寫 DB）。
class _World {
  _World(this.tester);

  final WidgetTester tester;
  final List<AppDatabase> dbs = [];
  final List<ProviderContainer> containers = [];
  AppDatabase? db;
  ProviderContainer? container;
  bool pumped = false;

  /// 名稱 → id（Background 建立時登記）。
  final accounts = <String, String>{};
  final categories = <String, String>{};
}

void _bind(GherkinRunner runner, _World w) {
  // ── Background ───────────────────────────────────────────
  runner.on(r'App 已完成首次設定$', (p) async {
    final db = DbFixture.create();
    w.dbs.add(db);
    w.db = db;
    w.pumped = false;
    w.accounts.clear();
    w.categories.clear();
  });

  runner.on(r'已建立分類{names}$', (p) async {
    final names =
        RegExp('「([^」]+)」').allMatches(p['names']!).map((m) => m.group(1)!).toList();
    for (var i = 0; i < names.length; i++) {
      final id = 'c-${w.categories.length}';
      await DbFixture.seedCategory(
        w.db!,
        id: id,
        kind: 'expense',
        name: names[i],
      );
      w.categories[names[i]] = id;
    }
  });

  runner.on(r'預算「{cat}」金額 {amt}、起始日 {day}$', (p) async {
    await DbFixture.seedBudget(
      w.db!,
      id: 'b-${w.db!.allBudgets().length}',
      categoryId: w.categories[p['cat']!],
      amountMinor: _amount(p['amt']!),
      periodStartDay: int.parse(p['day']!),
    );
  });

  runner.on(r'已建立帳戶「{name}」\(餘額 {amount}\)$', (p) async {
    final id = 'a-${w.accounts.length}';
    await DbFixture.seedAccount(
      w.db!,
      id: id,
      type: 'cash',
      name: p['name']!,
      opening: _amount(p['amount']!),
    );
    w.accounts[p['name']!] = id;
  });

  // ── Given：本期資料（fixture 直寫）─────────────────────────
  runner.on(r'本期{cat}已支出 {amt}$', (p) async {
    await DbFixture.seedTx(
      w.db!,
      id: 'tx-base-${w.db!.allTransactions().length}',
      kind: 'expense',
      amountMinor: _amount(p['amt']!),
      accountId: w.accounts['現金']!,
      category: w.categories[p['cat']!],
      occurredAt: Clock.now().millisecondsSinceEpoch,
    );
  });

  runner.on(r'本期{cat}含信用卡預扣 {amt}$', (p) async {
    await DbFixture.seedTx(
      w.db!,
      id: 'tx-pend-${w.db!.allTransactions().length}',
      kind: 'expense',
      amountMinor: _amount(p['amt']!),
      accountId: w.accounts['現金']!,
      category: w.categories[p['cat']!],
      occurredAt: Clock.now().millisecondsSinceEpoch,
      settlementStatus: 'pending',
    );
  });

  runner.on(r'收入目標 {goal} 且本月已入帳 {achieved}$', (p) async {
    await DbFixture.seedIncomeGoal(w.db!, id: 'g-0', amountMinor: _amount(p['goal']!));
    await DbFixture.seedTx(
      w.db!,
      id: 'tx-inc-${w.db!.allTransactions().length}',
      kind: 'income',
      amountMinor: _amount(p['achieved']!),
      accountId: w.accounts['現金']!,
      category: null,
      occurredAt: Clock.now().millisecondsSinceEpoch,
    );
  });

  runner.on(r'設定→通知→「預算警示」= {state}$', (p) async {
    await DbFixture.setSetting(w.db!, key: 'budget.notify_enabled', value: p['state']!);
  });

  // ── When：導航（M2 主殼第三分頁）──────────────────────────
  runner.on(r'開啟預算頁$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-預算')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'開啟總覽頁$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-總覽')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'開啟快速記帳頁$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('fab-quick-entry')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'輸入金額 {amount}$', (p) async {
    await w.tester.enterText(find.byKey(const Key('quick-entry-amount')), p['amount']!);
    await w.tester.pump();
  });

  // ── Then ─────────────────────────────────────────────────
  runner.on(r'顯示「{text}」$', (p) async {
    expect(w.tester.any(find.text(p['text']!, skipOffstage: false)), isTrue,
        reason: '應顯示「${p['text']}」');
  });

  runner.on(r'顯示「{text}」標籤$', (p) async {
    expect(w.tester.any(find.text(p['text']!, skipOffstage: false)), isTrue,
        reason: '應顯示「${p['text']}」標籤（FR-B5 預扣分量）');
  });

  runner.on(r'顯示「{text}」且為可點擊$', (p) async {
    // UI-P4：儲存鈕文案＝`OK 儲存`（PM 2026-10-23）——以包含比對。
    expect(find.textContaining(p['text']!), findsWidgets,
        reason: '應顯示含「${p['text']}」之鈕');
    final btn =
        w.tester.widget<FilledButton>(find.byKey(const Key('quick-entry-save')));
    expect(btn.onPressed, isNotNull, reason: '「${p['text']}」應為可點擊（超支不封鎖記帳）');
  });

  runner.on(r'進度條為警示色（{color}）$', (p) async {
    // 總覽橫幅與預算頁皆有同名進度條（同資料同色）——取第一個。
    final bar = w.tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('budget-progress-餐飲食品'), skipOffstage: false).first);
    final expected = switch (p['color']) {
      'orange' => Colors.orange,
      'red' => Colors.red,
      _ => throw FormatException('未知警示色：${p['color']}（dsl §3.3）'),
    };
    expect(bar.color, expected, reason: '進度條應為警示色（${p['color']}）');
  });
}

Future<void> _ensureApp(_World w) async {
  if (w.pumped) return;
  final container = ProviderContainer(overrides: [
    dbProvider.overrideWithValue(w.db!),
  ]);
  w.containers.add(container);
  w.container = container;
  await w.tester.pumpWidget(
    KeyedSubtree(
      key: ValueKey('app-shell-${w.dbs.length}'),
      child: UncontrolledProviderScope(container: container, child: const AppShell()),
    ),
  );
  await w.tester.pumpAndSettle();
  w.pumped = true;
}

int _amount(String s) => int.parse(s.trim().replaceAll(',', ''));
