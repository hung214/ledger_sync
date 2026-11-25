import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/intl.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/presentation/app_shell.dart';
import 'package:ledger_sync/presentation/screens/ledger/ledger_page.dart';
import 'package:ledger_sync/presentation/screens/overview/overview_page.dart';
import 'package:ledger_sync/presentation/screens/quick_entry/quick_date_time_picker.dart';
import 'package:ledger_sync/presentation/screens/quick_entry/quick_entry_controller.dart';
import 'package:ledger_sync/presentation/screens/quick_entry/quick_entry_page.dart';

import '../../test/helpers/in_memory_cloud_adapter.dart';
import '../../test/helpers/db_fixture.dart';
import '../../test/helpers/gherkin/gherkin.dart';

/// F01-FE 情境執行器（@FE @M1 @FR-Q @P0，6 情境；S1.11 @P1 @desktop 過濾）。
///
/// 來源：specs/plan/tests/frontend/F01_quick-entry.feature（sync_features.ps1
/// 同步副本，pubspec 資產入包——桌面 App 行程 CWD 非專案根，須 rootBundle 讀）。
/// 句型登記簿：specs/plan/tests/dsl.md §3。綁定：T-H7 自製 runner（TR-9）＋
/// integration_test；背景每情境重建 App（in-memory DB 直寫）。
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final doc = GherkinParser.parse(await rootBundle
      .loadString('integration_test/features/F01_quick-entry.feature'));

  testWidgets('F01-FE：快記 UI（6 情境：預填/對話框/Sticky/完成/時間/復原）',
      (tester) async {
    final w = _World(tester);
    final runner = GherkinRunner();
    _bind(runner, w);
    try {
      final executed = await runner.run(doc, tagFilter: (tags) {
        // 檔級標籤含 @P0（預設優先級）——情境級 @P1（S1.11 桌面快捷鍵，M2）
        // 以明確排除處理。
        return tags.contains('@FE') && !tags.contains('@P1');
      });
      expect(executed, 7, reason: 'F01-FE 應執行 7 個情境（@FE @P0 含 DBG-003 回歸；S1.11 @P1 M2 排除）');
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

  /// 本次 session 儲存過的金額（「明細即時顯示該 N 筆」以可見 session 筆數斷言，
  /// 背景歷史交易不計——綁定以金額文字識別，故情境金額須避開背景 120/30）。
  final sessionAmounts = <int>[];
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
    w.sessionAmounts.clear();
    // M1 無引導頁：啟動即主殼；帳戶/分類/歷史由後續 Given 直寫。
  });

  runner.on(r'已建立帳戶「{name}」\(餘額 {amount}\)$', (p) async {
    final id = 'a-${w.accounts.length}';
    await DbFixture.seedAccount(
      w.db!,
      id: id,
      type: 'cash', // FE 情境不涉類型語意（dsl.md §3.1）
      name: p['name']!,
      opening: _amount(p['amount']!),
    );
    w.accounts[p['name']!] = id;
  });

  runner.on(r'已建立分類{names}$', (p) async {
    final names =
        RegExp('「([^」]+)」').allMatches(p['names']!).map((m) => m.group(1)!).toList();
    for (final name in names) {
      final id = 'c-${w.categories.length}';
      await DbFixture.seedCategory(
        w.db!,
        id: id,
        kind: 'expense',
        name: name,
        isSystem: name == '其他',
      );
      w.categories[name] = id;
    }
  });

  runner.on(r'模擬系統時間為 {dt}$', (p) async => Clock.freeze(_dateTime(p['dt']!)));

  runner.on(r'歷史交易: {desc}$', (p) async {
    final base = Clock.now(); // feature 背景已先凍結（相對日以凍結時間為基準）
    for (final seg
        in p['desc']!.split(RegExp(r'[；;]')).map((s) => s.trim()).where((s) => s.isNotEmpty)) {
      final single = RegExp(
              r'^(今日|昨日) (\d{1,2}):(\d{2}) ([^/／]+)/([^/／/ ]+)/([^ ]+) (\d[\d,]*) 元$')
          .firstMatch(seg);
      if (single != null) {
        final day = single.group(1) == '昨日' ? 1 : 0;
        await _seedHistoryTx(
          w,
          DateTime(base.year, base.month, base.day - day, int.parse(single.group(2)!),
              int.parse(single.group(3)!)),
          accountName: single.group(4)!,
          categoryName: single.group(5)!,
          amount: _amount(single.group(7)!),
          merchant: single.group(6),
        );
        continue;
      }
      final weekly = RegExp(r'^本週(清晨|上午|下午|晚上)([^/／]+)/(\S+) (\d+) 筆$').firstMatch(seg);
      if (weekly != null) {
        final hour = const {'清晨': 3, '上午': 9, '下午': 15, '晚上': 21}[weekly.group(1)!];
        final n = int.parse(weekly.group(4)!);
        for (var k = 1; k <= n; k++) {
          await _seedHistoryTx(
            w,
            DateTime(base.year, base.month, base.day - k, hour!, 0),
            accountName: weekly.group(2)!,
            categoryName: weekly.group(3)!,
            amount: 30,
          );
        }
        continue;
      }
      throw FormatException('歷史段落句型未支援：$seg（請擴充綁定並先登記 dsl.md）');
    }
  });

  // ── Given：空帳本（DBG-003 回歸）──────────────────────────
  runner.on(r'帳本為全新空本（無帳戶/分類/交易）$', (p) async {
    // 以全新空 DB 替換；情境內尚未 pump（背景僅建資料），_ensureApp 將以空本啟動。
    final db = DbFixture.create();
    w.dbs.add(db);
    w.db = db;
    w.pumped = false;
    w.accounts.clear();
    w.categories.clear();
  });

  // ── Given：頁面與快記狀態 ──────────────────────────────────
  runner.on(r'使用者位於{page}頁$', (p) async {
    await _ensureApp(w);
    final page = _pageWidget(p['page']!);
    if (!w.tester.any(find.byType(page))) {
      // Given 語意：導航至該分頁。byKey 雙殼相容（DBG-006：macOS NSWindow
      // autosave frame 漂移 ≥900px 時為 Rail 殼——NavigationBar-specific
      // finder 會 0 widgets；F10 輪 nav keys 教訓）。
      await w.tester.tap(find.byKey(Key('nav-${p['page']}')));
      await w.tester.pumpAndSettle();
    }
    expect(w.tester.any(find.byType(page)), isTrue, reason: '應位於${p['page']}頁');
  });

  runner.on(r'快記頁已輸入金額 {amount}、帳戶={account}、分類={category}$', (p) async {
    await _ensureQuickEntry(w);
    final ctrl = w.container!.read(quickEntryControllerProvider.notifier);
    await w.tester.enterText(
        find.byKey(const Key('quick-entry-amount')), p['amount']!);
    ctrl.selectAccount(p['account']!);
    ctrl.selectCategory(p['category']!);
    await w.tester.pump();
  });

  runner.on(
      r'已儲存 {n} 筆（{account}/{category}/{merchant}）並於對話框按「繼續」$',
      (p) async {
    await _ensureQuickEntry(w);
    for (var i = 0; i < int.parse(p['n']!); i++) {
      await _fillAndSave(w,
          account: p['account']!,
          category: p['category']!,
          merchant: p['merchant'],
          amount: '120');
      await w.tester.tap(find.text('繼續'));
      await w.tester.pumpAndSettle();
    }
  });

  runner.on(r'已於本 session 儲存 {n} 筆$', (p) async {
    await _ensureQuickEntry(w);
    final n = int.parse(p['n']!);
    for (var i = 0; i < n; i++) {
      await _fillAndSave(w, amount: '${100 + i}');
      if (i < n - 1) {
        await w.tester.tap(find.text('繼續'));
        await w.tester.pumpAndSettle();
      }
    }
  });

  // ── When ─────────────────────────────────────────────────
  runner.on(r'開啟快速記帳頁並連續記錄 {n} 筆後按下「完成」$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('fab-quick-entry')));
    await w.tester.pumpAndSettle();
    final n = int.parse(p['n']!);
    const amounts = ['101', '102', '103']; // 避開背景歷史金額（120/30）供識別
    for (var i = 0; i < n; i++) {
      await _fillAndSave(w, amount: amounts[i < 3 ? i : 2]);
      if (i < n - 1) {
        await w.tester.tap(find.text('繼續'));
        await w.tester.pumpAndSettle();
      }
    }
    await w.tester.tap(find.text('完成'));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'開啟快速記帳頁$', (p) async => _ensureQuickEntry(w));

  runner.on(r'按下「{label}」$', (p) async {
    final label = p['label']!;
    // UI-P4：儲存鈕文案＝「OK 儲存」→ 以 key 精準鎖定；其餘（繼續/完成/復原…）
    // 以包含比對（對話框動作鈕）。
    final target = label.contains('儲存')
        ? find.byKey(const Key('quick-entry-save'))
        : find.textContaining(label).first;
    await w.tester.tap(target);
    await w.tester.pumpAndSettle();
  });

  runner.on(r'點擊時間欄位$', (p) async {
    await w.tester.tap(find.byKey(const Key('quick-entry-time')));
    await w.tester.pumpAndSettle();
  });

  // ── Then：預填與欄位 ──────────────────────────────────────
  runner.on(r'{field}預填為「{value}」$', (p) async {
    final field = p['field']!;
    final value = p['value']!;
    if (field == '分類') {
      // v3（PM 2026-10-24）：分類欄（彈窗入口）顯示所選分類（emoji 前綴）。
      expect(
          find.descendant(
              of: find.byKey(const Key('quick-entry-category')),
              matching: find.textContaining(value)),
          findsOneWidget,
          reason: '分類欄應顯示「$value」（FR-Q4 預填）');
      return;
    }
    final finder = find.descendant(
        of: find.byType(QuickEntryPage),
        matching: _presetFinder(field, value));
    expect(w.tester.any(finder), isTrue,
        reason: '$field 應預填為「$value」（FR-Q4）');
  });

  runner.on(r'金額欄為空且鍵盤已聚焦$', (p) async {
    final amountState = _amountEditableState(w);
    expect(amountState.widget.controller.text, isEmpty, reason: '金額欄應為空');
    // FR-Q1：金額欄標記 autofocus（契約）。真值 `focusNode.hasFocus` 於
    // macOS 整合測試會因**視窗未取得焦點**而不穩定（既有 flaky，非產品缺陷）
    // ——決定性焦點驗證改由 widget test 承擔（PM 2026-10-22 分流原則）。
    expect(amountState.widget.autofocus, isTrue,
        reason: '金額欄應標記 autofocus（FR-Q1）');
  });

  runner.on(r'金額欄為空$', (p) async {
    expect(_amountEditableState(w).widget.controller.text, isEmpty, reason: '金額欄應為空');
  });

  runner.on(r'儲存按鈕為禁用狀態$', (p) async {
    final btn =
        w.tester.widget<FilledButton>(find.byKey(const Key('quick-entry-save')));
    expect(btn.onPressed, isNull, reason: '儲存應為禁用（DSL §3.3：enabled=false）');
  });

  // ── Then：對話框與計時 ────────────────────────────────────
  runner.on(r'彈出對話框「{text}」且提供「{a}」「{b}」「{c}」三個動作$', (p) async {
    expect(find.text(p['text']!), findsOneWidget, reason: '對話框標題');
    for (final k in const ['a', 'b', 'c']) {
      expect(w.tester.any(find.text(p[k]!)), isTrue, reason: '動作「${p[k]}」應存在');
    }
  });

  runner.on(r'交易入庫耗時 < 300ms（UI 計時）$', (p) async {
    final state = w.container!.read(quickEntryControllerProvider);
    expect(state.lastSaveMs, isNotNull, reason: '應已完成儲存（NFR-01 UI 計時）');
    expect(state.lastSaveMs!, lessThan(300), reason: 'NFR-01：入庫耗時 < 300ms');
  });

  runner.on(r'^顯示「{text}」$', (p) async {
    final text = p['text']!;
    if (text == '日期時間選擇器') {
      expect(find.byType(QuickDateTimePicker), findsOneWidget,
          reason: '時間選擇器應開於原頁（FR-Q8）');
    } else {
      expect(w.tester.any(find.text(text)), isTrue, reason: '應顯示「$text」');
    }
  });

  runner.on(r'^不顯示「{text}」$', (p) async {
    expect(find.text(p['text']!), findsNothing, reason: '不應顯示「${p['text']}」');
  });

  // ── Then：分頁與明細 ──────────────────────────────────────
  runner.on(r'明細頁即時顯示該 {n} 筆$', (p) async {
    final n = int.parse(p['n']!);
    // 「該 N 筆」= 本次 session 所記且未被復原者（背景歷史不計）；
    // IndexedStack/推入路由下明細可能非作用中 → skipOffstage:false。
    var visible = 0;
    for (final amt in w.sessionAmounts) {
      if (w.tester.any(find.text('-$amt', skipOffstage: false))) visible++;
    }
    expect(visible, n, reason: '本次 session 應有 $n 筆即時顯示於明細');
  });
}

// ── 綁定輔助 ──────────────────────────────────────────────

Future<void> _ensureApp(_World w) async {
  if (w.pumped) return;
  final container = ProviderContainer(overrides: [
    dbProvider.overrideWithValue(w.db!),
    // 啟動同步鉤子（FR-Y11 afterSave——F07-BE 接線）防 UnimplementedError。
    syncCoordinatorProvider.overrideWithValue(
        SyncCoordinator(w.db!, InMemoryCloudAdapter(), deviceId: 'd-A')),
  ]);
  w.containers.add(container);
  w.container = container;
  // 每情境以唯一 Key 強制重建整棵樹——否則 const AppShell 會複用 element，
  // Navigator 路由堆疊（前情境的快記頁/對話框）殘留並掛著舊 container/DB。
  await w.tester.pumpWidget(
    KeyedSubtree(
      key: ValueKey('app-shell-${w.dbs.length}'),
      child: UncontrolledProviderScope(container: container, child: const AppShell()),
    ),
  );
  await w.tester.pumpAndSettle();
  w.pumped = true;
}

Future<void> _ensureQuickEntry(_World w) async {
  await _ensureApp(w);
  if (w.tester.any(find.byType(QuickEntryPage))) return;
  await w.tester.tap(find.byKey(const Key('fab-quick-entry')));
  await w.tester.pumpAndSettle();
  expect(w.tester.any(find.byType(QuickEntryPage)), isTrue, reason: '快記頁應已開啟');
}

/// 填欄位（enterText 驅動 onChanged → controller）＋儲存。
Future<void> _fillAndSave(
  _World w, {
  String? account,
  String? category,
  String? merchant,
  required String amount,
}) async {
  final ctrl = w.container!.read(quickEntryControllerProvider.notifier);
  await w.tester.enterText(find.byKey(const Key('quick-entry-amount')), amount);
  if (merchant != null) {
    await w.tester.enterText(find.byKey(const Key('quick-entry-merchant')), merchant);
  }
  if (account != null) ctrl.selectAccount(account);
  if (category != null) ctrl.selectCategory(category);
  await w.tester.pump();
  ctrl.save();
  w.sessionAmounts.add(int.parse(amount));
  await w.tester.pumpAndSettle();
}

Future<void> _seedHistoryTx(
  _World w,
  DateTime at, {
  required String accountName,
  required String categoryName,
  required int amount,
  String? merchant,
}) async {
  await DbFixture.seedTx(
    w.db!,
    id: 'tx-h-${w.db!.allTransactions().length}',
    kind: 'expense',
    amountMinor: amount,
    accountId: w.accounts[accountName]!,
    category: w.categories[categoryName],
    merchant: merchant,
    occurredAt: at.millisecondsSinceEpoch,
  );
}

EditableTextState _amountEditableState(_World w) {
  final finder = find.descendant(
      of: find.byKey(const Key('quick-entry-amount')),
      matching: find.byType(EditableText));
  return w.tester.state<EditableTextState>(finder);
}

Finder _presetFinder(String field, String value) {
  switch (field) {
    case '時間':
      final dt = value == '現在' ? Clock.now() : _dateTime(value);
      // UI-P4 日期列（PM 2026-10-23）：`yyyy/MM/dd（週）HH:mm` 為單一 Text
      // ——以「同時含日期與時分」的述詞比對（非連續子字串）。
      final date = DateFormat('yyyy/MM/dd').format(dt);
      final hm = DateFormat('HH:mm').format(dt);
      return find.byWidgetPredicate((widget) =>
          widget is Text &&
          (widget.data ?? '').contains(date) &&
          (widget.data ?? '').contains(hm));
    default: // 帳戶／分類／商家
      return find.text(value);
  }
}

Type _pageWidget(String page) {
  switch (page) {
    case '總覽':
      return OverviewPage;
    case '明細':
      return LedgerPage;
  }
  throw FormatException('未知分頁：$page（請擴充綁定）');
}

int _amount(String s) => int.parse(s.trim().replaceAll(',', ''));

DateTime _dateTime(String s) {
  final m = RegExp(r'^(\d{4})/(\d{2})/(\d{2})(?: (\d{1,2}):(\d{2}))?$').firstMatch(s.trim());
  if (m == null) throw FormatException('日期時間格式未支援：$s（dsl.md §1-3）');
  return DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    m.group(4) == null ? 0 : int.parse(m.group(4)!),
    m.group(5) == null ? 0 : int.parse(m.group(5)!),
  );
}
