import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ledger_sync/application/credit_card/billing_cycle_service.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/presentation/app_shell.dart';
import 'package:ledger_sync/presentation/screens/credit_card/credit_card_page.dart';

import '../../test/helpers/db_fixture.dart';
import '../../test/helpers/gherkin/gherkin.dart';
import '../../test/helpers/notification_spy.dart';

/// F04-FE 情境執行器（@FE @M3 @FR-C，5 情境：帳單呈現/全額繳/部分繳/
/// 設定顯示/逾期標示）。
///
/// 來源：specs/plan/tests/frontend/F04_credit-card-billing.feature（rootBundle 資產）。
/// 句型登記簿：specs/plan/tests/dsl.md §3。
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final doc = GherkinParser.parse(await rootBundle
      .loadString('integration_test/features/F04_credit-card-billing.feature'));

  testWidgets('F04-FE：信用卡帳單 UI（5 情境）', (tester) async {
    final w = _World(tester);
    final runner = GherkinRunner();
    _bind(runner, w);
    try {
      final executed = await runner.run(
        doc,
        tagFilter: (tags) => tags.contains('@FE'),
      );
      expect(executed, 5, reason: 'F04-FE 應執行 5 個情境（@FE @P0）');
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
  final NotificationSpy spy = NotificationSpy();

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
    w.spy.clear();
  });

  // 信用卡帳戶變體——須先於一般帳戶綁定（前綴碰撞教訓）。
  runner.on(r'已建立帳戶「{name}」\(餘額 {amount}\)（結帳日 {day} 號、歸屬={rule}）$',
      (p) async {
    final accountId = 'a-${w.accounts.length}';
    await DbFixture.seedCreditCard(
      w.db!,
      accountId: accountId,
      name: p['name']!,
      statementDay: int.parse(p['day']!),
      dueOffsetDays: 15,
      boundaryRule: p['rule'] == '當天算本期' ? 'include' : 'exclude',
    );
    w.accounts[p['name']!] = accountId;
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

  runner.on(r'已建立分類{names}$', (p) async {
    final names =
        RegExp('「([^」]+)」').allMatches(p['names']!).map((m) => m.group(1)!).toList();
    for (var i = 0; i < names.length; i++) {
      final id = 'c-${w.categories.length}';
      await DbFixture.seedCategory(w.db!, id: id, kind: 'expense', name: names[i]);
      w.categories[names[i]] = id;
    }
  });

  runner.on(r'模擬系統時間為 {dt}$', (p) async => Clock.freeze(_dateTime(p['dt']!)));

  // ── Given：預扣（上一期）＋結帳（fixture 觸發）─────────────
  runner.on(r'已有 {n} 筆預扣交易於「{card}」共 {amount}（上一期）$', (p) async {
    final cardId = w.accounts[p['card']!]!;
    // 上一期：相對凍結時間之最近已關閉週期（7/6 → 6/6~7/5）。
    final now = Clock.now();
    final detail = w.db!.creditCardDetail(cardId)!;
    final statementDate = DateTime(now.year, now.month, detail.statementDay);
    final end = statementDate.subtract(const Duration(days: 1));
    final start = DateTime(end.year, end.month - 1, detail.statementDay + 1, 12);
    final count = int.parse(p['n']!);
    final total = _amount(p['amount']!);
    final each = total ~/ count;
    final extra = total - each * count;
    for (var i = 0; i < count; i++) {
      await DbFixture.seedTx(
        w.db!,
        id: 'tx-f04fe-$i',
        kind: 'expense',
        amountMinor: each + (i < extra ? 1 : 0),
        accountId: cardId,
        category: w.categories['購物'],
        occurredAt: start.add(Duration(days: i)).millisecondsSinceEpoch,
        settlementStatus: 'pending',
      );
    }
  });

  runner.on(r'執行 BillingCycleService.run（「{card}」）（經 fixture 觸發）$', (p) async {
    final service = BillingCycleService(w.db!, w.spy);
    service.run(w.accounts[p['card']!]!);
  });

  // ── When：導航與繳款互動 ──────────────────────────────────
  runner.on(r'開啟信用卡頁$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-總覽')));
    await w.tester.pumpAndSettle();
    // 總覽同時可能顯示「示例卡」於帳戶卡與最近交易列——取第一個（帳戶卡）。
    await w.tester.tap(find.text('示例卡').first);
    await w.tester.pumpAndSettle();
    expect(w.tester.any(find.byType(CreditCardPage)), isTrue, reason: '信用卡頁應已開啟');
  });

  runner.on(r'開啟信用卡頁並按下「{label}」$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-總覽')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.text('示例卡').first);
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('repay-button')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'按下「{label}」$', (p) async {
    await w.tester.tap(find.text(p['label']!));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'按下「{label1}」→「{label2}」輸入 {amount} 並確認$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-總覽')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.text('示例卡').first);
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('repay-button')));
    await w.tester.pumpAndSettle();
    await w.tester.enterText(find.byKey(const Key('repay-amount')), p['amount']!);
    await w.tester.pump();
    await w.tester.tap(find.byKey(const Key('repay-confirm')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'開啟卡片設定頁$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-總覽')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.text('示例卡').first);
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('card-settings-entry')));
    await w.tester.pumpAndSettle();
  });

  // ── Then ─────────────────────────────────────────────────
  // 徽章變體（頁首 須先於一般徽章）——須先於通用顯示句型。
  runner.on(r'顯示「{text}」徽章（頁首）$', (p) async {
    expect(
        w.tester.any(find.byKey(Key('badge-${p['text']!}'), skipOffstage: false)),
        isTrue,
        reason: '頁首應顯示「${p['text']}」徽章');
  });

  runner.on(r'顯示「{text}」徽章$', (p) async {
    expect(
        w.tester.any(find.byKey(Key('badge-${p['text']!}'), skipOffstage: false)),
        isTrue,
        reason: '應顯示「${p['text']}」徽章');
  });

  runner.on(r'顯示「{text}」$', (p) async {
    expect(w.tester.any(find.text(p['text']!, skipOffstage: false)), isTrue,
        reason: '應顯示「${p['text']}」');
  });

  runner.on(r'帳戶「{name}」餘額顯示為 {amount}$', (p) async {
    // 推入路由時主殼 offstage（find 預設略 offstage）——先返回主殼。
    final navigator = w.tester.state<NavigatorState>(find.byType(Navigator).first);
    if (navigator.canPop()) {
      await navigator.maybePop();
      await w.tester.pumpAndSettle();
    }
    await w.tester.tap(find.byKey(const Key('nav-總覽')));
    await w.tester.pumpAndSettle();
    final fmt = _thousands(_amount(p['amount']!));
    expect(w.tester.any(find.text('餘額 $fmt', skipOffstage: false)), isTrue,
        reason: '總覽餘額卡（千分位）');
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

String _thousands(int amount) {
  final s = amount.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final rev = s.length - i;
    buf.write(s[i]);
    if (rev > 1 && rev % 3 == 1) buf.write(',');
  }
  return '${amount < 0 ? '-' : ''}$buf';
}

int _amount(String s) {
  final m = RegExp(r'^-?[\d,]+').firstMatch(s.trim());
  if (m == null) throw FormatException('金額格式未支援：$s');
  return int.parse(m.group(0)!.replaceAll(',', ''));
}
