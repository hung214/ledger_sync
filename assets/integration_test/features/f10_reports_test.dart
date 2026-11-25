import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/intl.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/presentation/app_shell.dart';
import 'package:ledger_sync/presentation/screens/ledger/ledger_page.dart';

import '../../test/helpers/db_fixture.dart';
import '../../test/helpers/gherkin/gherkin.dart';

/// F10-FE 情境執行器（@FE @M2 @FR-R，3 情境：占比趨勢／複合篩選／CSV 匯出）。
///
/// 來源：specs/plan/tests/frontend/F10_reports-search.feature（sync_features.ps1
/// 同步副本，pubspec 資產入包）。句型登記簿：specs/plan/tests/dsl.md §3。
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final doc = GherkinParser.parse(
      await rootBundle.loadString('integration_test/features/F10_reports-search.feature'));

  testWidgets('F10-FE：報表與搜尋 UI（3 情境：占比趨勢／複合篩選／CSV 匯出）', (tester) async {
    final w = _World(tester);
    final runner = GherkinRunner();
    _bind(runner, w);
    try {
      final executed = await runner.run(
        doc,
        // M2 當前 feature：P0＋P1 皆在範圍（tasks.md T-F10-FE＝3 情境）。
        tagFilter: (tags) => tags.contains('@FE'),
      );
      expect(executed, 3, reason: 'F10-FE 應執行 3 個情境（@FE @P0＋@P1 屬 M2 範圍）');
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

  final categories = <String, String>{};
  final seededIdsByMonth = <int, List<String>>{};
}

void _bind(GherkinRunner runner, _World w) {
  // ── Background ───────────────────────────────────────────
  runner.on(r'App 已完成首次設定$', (p) async {
    final db = DbFixture.create();
    w.dbs.add(db);
    w.db = db;
    w.pumped = false;
    w.categories.clear();
    w.seededIdsByMonth.clear();
  });

  /// `已存在 6 月支出: 餐飲食品 3 筆共 900、交通運輸 2 筆共 400（經 fixture）`
  runner.on(r'已存在 {month} 月支出: {desc}（經 fixture）$', (p) async {
    final month = int.parse(p['month']!);
    final year = Clock.now().year;
    for (final seg
        in p['desc']!.split('、').map((s) => s.trim()).where((s) => s.isNotEmpty)) {
      final m = RegExp(r'^(.+?) (\d+) 筆(?:共 (\d+)| (\d+))$').firstMatch(seg);
      if (m == null) {
        throw FormatException('月支出段落未支援：$seg（dsl.md §2.1）');
      }
      final catName = m.group(1)!;
      final count = int.parse(m.group(2)!);
      final total = _amount(m.group(3) ?? m.group(4)!);
      final catId = _getOrCreateCategory(w, catName);
      final accountId = _getOrCreateAccount(w);
      final each = m.group(3) != null ? total ~/ count : total;
      for (var i = 0; i < count; i++) {
        final id = 'tx-f10fe-${w.db!.allTransactions().length}';
        await DbFixture.seedTx(
          w.db!,
          id: id,
          kind: 'expense',
          amountMinor: each,
          accountId: accountId,
          category: catId,
          occurredAt: DateTime(year, month, i + 1, 12).millisecondsSinceEpoch,
        );
        w.seededIdsByMonth.putIfAbsent(month, () => []).add(id);
      }
    }
  });

  runner.on(r'其中 {n} 筆 {month} 月{cat}備註含「{kw}」$', (p) async {
    final month = int.parse(p['month']!);
    final ids = w.seededIdsByMonth[month] ?? const [];
    final catId = w.categories[p['cat']!];
    var updated = 0;
    for (final id in ids) {
      if (updated >= int.parse(p['n']!)) break;
      final row = w.db!.transactionById(id);
      if (row == null || row.categoryId != catId) continue;
      w.db!.setTransactionNote(id, p['kw']);
      updated++;
    }
  });

  // When/Then：統計頁（F10 S10.1；FR-R2 呈現面）
  runner.on(r'開啟統計頁並選擇 {month} 月$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-統計')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('stats-month')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.text('${p['month']}月').last);
    await w.tester.pumpAndSettle();
  });

  runner.on(r'顯示「{text}」$', (p) async {
    expect(w.tester.any(find.text(p['text']!, skipOffstage: false)), isTrue,
        reason: '應顯示「${p['text']}」');
  });

  runner.on(r'月趨勢圖 {m1} 月 = {v1}、{m2} 月 = {v2}$', (p) async {
    final fmt = NumberFormat('#,###');
    for (final (m, v) in [(p['m1']!, p['v1']!), (p['m2']!, p['v2']!)]) {
      expect(
        w.tester.any(find.text('$m月 ${fmt.format(_amount(v))}', skipOffstage: false)),
        isTrue,
        reason: '月趨勢 $m 月應為 ${fmt.format(_amount(v))}',
      );
    }
  });

  // When/Then：複合篩選互動（F10 S10.2；FR-R3）
  runner.on(r'篩選 期間={period}、分類={cat}$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-明細')));
    await w.tester.pumpAndSettle();
    // 期間選擇器 → 選項（句型參數含「月」：6月 → 選項文字「6 月」）
    final monthNum = p['period']!.replaceAll('月', '');
    await w.tester.tap(find.byKey(const Key('filter-period')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.text('$monthNum 月').last);
    await w.tester.pumpAndSettle();
    // 分類選擇器 → 選項
    await w.tester.tap(find.byKey(const Key('filter-category')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.text(p['cat']!).last);
    await w.tester.pumpAndSettle();
  });

  runner.on(r'關鍵字輸入「{kw}」$', (p) async {
    await w.tester.enterText(find.byKey(const Key('filter-keyword')), p['kw']!);
    await w.tester.pumpAndSettle();
  });

  runner.on(r'僅顯示 {n} 筆（三條件交集）$', (p) async {
    _expectTxCount(w, int.parse(p['n']!));
  });

  runner.on(r'顯示篩選 chips 可逐一移除$', (p) async {
    expect(
      w.tester.any(find.byType(InputChip, skipOffstage: false)),
      isTrue,
      reason: '篩選條件應以 chips 呈現（可逐一移除）',
    );
  });

  runner.on(r'清除全部篩選$', (p) async {
    await w.tester.tap(find.byKey(const Key('filter-clear')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'顯示全部 {n} 筆$', (p) async {
    _expectTxCount(w, int.parse(p['n']!));
  });

  // Given/When/Then：CSV 匯出（F10 S10.3；FR-R4）
  runner.on(r'篩選生效（期間={period}）$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-明細')));
    await w.tester.pumpAndSettle();
    final monthNum2 = p['period']!.replaceAll('月', '');
    await w.tester.tap(find.byKey(const Key('filter-period')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.text('$monthNum2 月').last);
    await w.tester.pumpAndSettle();
  });

  runner.on(r'按下「{label}」$', (p) async {
    await w.tester.tap(find.text(p['label']!));
    await w.tester.pumpAndSettle();
  });
}

/// 明細列計數（篩選後；IndexedStack 下以 skipOffstage 取得）。
void _expectTxCount(_World w, int n) {
  expect(w.tester.widgetList<TxTile>(find.byType(TxTile, skipOffstage: false)),
      hasLength(n));
}

/// 分類隱式建立。
String _getOrCreateCategory(_World w, String name) {
  final existing = w.categories[name];
  if (existing != null) return existing;
  final id = 'c-${w.categories.length}';
  DbFixture.seedCategory(w.db!, id: id, kind: 'expense', name: name);
  w.categories[name] = id;
  return id;
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

/// 帳戶隱式建立。
String _getOrCreateAccount(_World w) {
  final accounts = w.db!.allAccounts();
  if (accounts.isNotEmpty) return accounts.first.id;
  DbFixture.seedAccount(w.db!, id: 'a-0', type: 'cash', name: '現金');
  return 'a-0';
}

int _amount(String s) => int.parse(s.trim().replaceAll(',', ''));
