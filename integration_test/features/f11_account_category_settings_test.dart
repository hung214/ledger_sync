import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ledger_sync/application/accounts/account_service.dart';
import 'package:ledger_sync/application/first_run_bootstrap.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/presentation/app_shell.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../../test/helpers/db_fixture.dart';
import '../../test/helpers/gherkin/gherkin.dart';

/// F11-FE 情境執行器（@FE @M8 @FR-A7/@FR-B1/@FR-O1，12 情境——
/// 含 v1.9 子分類編輯即時連動快記）。
///
/// 來源：specs/plan/tests/frontend/F11_account-category-settings.feature。
/// 句型登記簿：specs/plan/tests/dsl.md §4.5（v1.6）。
///
/// **檔案 DB**：外觀持久化須重啟驗證——每情境以暫存檔 DB 開啟（非 in-memory），
/// 「關閉並重新啟動 App」＝dispose container → 關檔 → 重開 → 新 container。
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final doc = GherkinParser.parse(await rootBundle
      .loadString('integration_test/features/F11_account-category-settings.feature'));

  testWidgets('F11-FE：帳戶/分類設定與外觀（12 情境）', (tester) async {
    final w = _World(tester);
    final runner = GherkinRunner();
    _bind(runner, w);
    try {
      final executed =
          await runner.run(doc, tagFilter: (tags) => tags.contains('@FE'));
      expect(executed, 12, reason: 'F11-FE 應執行 12 個情境');
      // ignore: avoid_print
      print(runner.log.join('\n'));
    } finally {
      await w.reset();
    }
  });
}

class _World {
  _World(this.tester);

  final WidgetTester tester;
  Directory? dir;
  AppDatabase? db;
  ProviderContainer? container;
  bool pumped = false;
  int scenarios = 0;

  /// 情境重置：關閉舊資源＋開新暫存檔 DB（每情境獨立）。
  Future<void> reset() async {
    container?.dispose();
    container = null;
    db?.close();
    db = null;
    pumped = false;
    dir = await Directory.systemTemp.createTemp('ledger_f11fe');
    db = AppDatabase.open('${dir!.path}/ledger.db');
    await FirstRunBootstrap.seedIfNeeded(db!);
    scenarios++;
  }
}

Future<void> _ensureApp(_World w) async {
  if (w.pumped) return;
  final db = w.db!;
  final container = ProviderContainer(overrides: [
    dbProvider.overrideWithValue(db),
  ]);
  w.container = container;
  await w.tester.pumpWidget(
    KeyedSubtree(
      key: ValueKey('app-shell-${w.scenarios}-${identityHashCode(container)}'),
      child:
          UncontrolledProviderScope(container: container, child: const AppShell()),
    ),
  );
  await w.tester.pumpAndSettle();
  w.pumped = true;
}

/// 設定 → 子頁導航（Hub 兩層）。
Future<void> _openSettings(_World w, {required String subKey}) async {
  await _ensureApp(w);
  // 前一情境可能停在推入頁——先回根（否則 app-settings 被遮擋）。
  final navigator = w.tester.state<NavigatorState>(find.byType(Navigator).first);
  navigator.popUntil((r) => r.isFirst);
  await w.tester.pumpAndSettle();
  await w.tester.tap(find.byKey(const Key('app-settings')));
  await w.tester.pumpAndSettle();
  await w.tester.tap(find.byKey(Key(subKey)));
  await w.tester.pumpAndSettle();
}

void _bind(GherkinRunner runner, _World w) {
  // ── Background ───────────────────────────────────────────
  runner.on(r'App 已完成首次設定$', (p) async {
    await w.reset(); // 每情境獨立暫存檔 DB（可重啟驗持久化）
  });

  runner.on(r'內建預設帳戶「{name}」與分類集$', (p) async {
    // Bootstrap 已於 reset 播種（現金＋內建分類集）——此處僅確認。
    expect(w.db!.allAccounts().any((a) => a.name == p['name']!), isTrue);
  });

  // ── 帳戶管理 ────────────────────────────────────────────
  runner.on(r'開啟設定→帳戶管理$', (p) async {
    await _openSettings(w, subKey: 'settings-accounts');
  });

  runner.on(r'顯示帳戶列表含「{name}」與類型與餘額$', (p) {
    expect(w.tester.any(find.byKey(Key('acct-row-${p['name']}'))), isTrue,
        reason: '帳戶列表應含「${p['name']}」');
    expect(find.textContaining('${p['name']} · '), findsWidgets,
        reason: '列應顯示類型與餘額');
  });

  runner.on(r'新增帳戶「{name}」類型 {label}、期初 {amt}、關閉「計入合併統計」$',
      (p) async {
    await w.tester.tap(find.byKey(const Key('acct-add')));
    await w.tester.pumpAndSettle();
    await w.tester.enterText(find.byKey(const Key('acct-name')), p['name']!);
    await w.tester.tap(find.byKey(const Key('acct-type')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.textContaining(p['label']!).last);
    await w.tester.pumpAndSettle();
    await w.tester.enterText(find.byKey(const Key('acct-opening')), p['amt']!);
    await w.tester.tap(find.byKey(const Key('acct-include-totals')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('acct-save')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'帳戶列表顯示「{name}」且標示「不計入合併」$', (p) {
    expect(w.tester.any(find.byKey(Key('acct-row-${p['name']}'))), isTrue);
    expect(find.text('不計入合併'), findsWidgets, reason: '排除標示（FR-A2）');
  });

  // 長句型先註冊（lazy 前綴碰撞——session 教訓）。
  runner.on(r'帳戶「{name}」餘額 {amt} 且不計入合併統計$', (p) async {
    final service = AccountService(w.db!);
    final existing = service.all().where((a) => a.name == p['name']!);
    if (existing.isNotEmpty) {
      service.update(existing.first.id,
          openingMinor: int.parse(p['amt']!.replaceAll(',', '')),
          includeInTotals: false);
      return;
    }
    service.create(
        type: 'cash',
        name: p['name']!,
        openingMinor: int.parse(p['amt']!.replaceAll(',', '')),
        includeInTotals: false);
  });

  runner.on(r'帳戶「{name}」餘額 {amt}$', (p) async {
    // 資料前置（服務直寫；UI 呈現由後續步驟驗證）。
    final service = AccountService(w.db!);
    final row = service.all().firstWhere((a) => a.name == p['name']!);
    service.update(row.id,
        openingMinor: int.parse(p['amt']!.replaceAll(',', '')));
  });

  runner.on(r'開啟總覽$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-總覽')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'資產合計顯示 {amt}$', (p) {
    expect(find.text('資產'), findsOneWidget, reason: '總覽統計卡');
    expect(find.text(p['amt']!), findsWidgets,
        reason: '資產合計（FR-A6：僅計入合併統計帳戶）');
  });

  runner.on(r'帳戶卡仍顯示「{name}」餘額 {amt}$', (p) {
    expect(find.text('餘額 ${p['amt']}'), findsWidgets,
        reason: '個別帳戶餘額獨立顯示（合計排除不改變個別值）');
  });

  runner.on(r'帳戶「{name}」有本期未繳帳單$', (p) async {
    // 資料前置：信用卡＋一筆預扣支出（settlement=pending）→ 未繳 > 0。
    final service = AccountService(w.db!);
    service.create(type: 'credit', name: p['name']!);
    final card = service.all().firstWhere((a) => a.name == p['name']!);
    await DbFixture.seedTx(w.db!,
        id: 'tx-f11-pending',
        kind: 'expense',
        amountMinor: 5000,
        accountId: card.id,
        merchant: '預扣商店',
        occurredAt: DateTime.now().millisecondsSinceEpoch,
        settlementStatus: 'pending');
  });

  runner.on(r'設定→帳戶管理→刪除「{name}」$', (p) async {
    await _openSettings(w, subKey: 'settings-accounts');
    await w.tester.tap(find.byKey(Key('acct-delete-${p['name']}')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'顯示「{text}」$', (p) {
    expect(find.textContaining(p['text']!), findsWidgets,
        reason: '應顯示「${p['text']}」');
  });

  runner.on(r'帳戶列表仍含「{name}」$', (p) {
    expect(w.tester.any(find.byKey(Key('acct-row-${p['name']}'))), isTrue,
        reason: '被拒絕的刪除不得影響帳戶');
  });

  runner.on(r'設定→帳戶管理→編輯「{from}」為「{to}」、類型 {label}$', (p) async {
    await _openSettings(w, subKey: 'settings-accounts');
    await w.tester.tap(find.byKey(Key('acct-edit-${p['from']}')));
    await w.tester.pumpAndSettle();
    await w.tester.enterText(find.byKey(const Key('acct-name')), p['to']!);
    await w.tester.tap(find.byKey(const Key('acct-type')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.textContaining(p['label']!).last);
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('acct-save')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'明細帳戶列顯示「{name}」$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-明細')));
    await w.tester.pumpAndSettle();
    expect(find.textContaining(p['name']!), findsWidgets,
        reason: '明細帳戶 chips 即時反映（FR-A7）');
  });

  runner.on(r'總覽帳戶卡顯示「{name}」$', (p) async {
    await w.tester.tap(find.byKey(const Key('nav-總覽')));
    await w.tester.pumpAndSettle();
    expect(find.text(p['name']!), findsWidgets, reason: '總覽帳戶卡即時反映');
  });

  // ── 分類管理 ────────────────────────────────────────────
  runner.on(r'開啟設定→分類管理（{kind}）$', (p) async {
    await _openSettings(w, subKey: 'settings-categories');
  });

  runner.on(r'新增分類「{name}」（圖示 {icon}、顏色 {color}）$', (p) async {
    await w.tester.tap(find.byKey(const Key('cat-add')));
    await w.tester.pumpAndSettle();
    final nameField = find.byKey(const Key('cat-name'));
    if (!w.tester.any(nameField)) {
      // ignore: avoid_print
      print('[F11 診斷] cat-name 未命中——當前 widget keys：');
      for (final e in w.tester.allWidgets) {
        final k = e.key;
        if (k != null) {
          // ignore: avoid_print
          print('  $k (${e.runtimeType})');
        }
      }
    }
    await w.tester.enterText(nameField, p['name']!);
    // emoji 圖示制（PM 2026-10-23）：表單圖示 chip key＝`cat-icon-{emoji}`；
    // feature 給中文語意（貓/餐飲食品…）→ 對映圖示庫 emoji。
    final iconKey = switch (p['icon']) {
      '貓' => '🐱',
      '餐飲食品' => '🍜',
      '交通運輸' => '🚗',
      '家' => '🏠',
      _ => p['icon']!, // 已是 emoji（圖示庫值）
    };
    final colorKey = switch (p['color']) {
      '紫' => 'purple',
      '紅' => 'red',
      '黃' => 'amber',
      '藍' => 'blue',
      _ => 'teal',
    };
    // 圖示庫為捲動區——先捲入再點（否則 tap 落空、靜默不改值）。
    final iconChip = find.byKey(Key('cat-icon-$iconKey'));
    await w.tester.ensureVisible(iconChip);
    await w.tester.pumpAndSettle();
    await w.tester.tap(iconChip);
    await w.tester.pumpAndSettle();
    final colorChip = find.byKey(Key('cat-color-$colorKey'));
    await w.tester.ensureVisible(colorChip);
    await w.tester.pumpAndSettle();
    await w.tester.tap(colorChip);
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('cat-save')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'將「{name}」拖曳至「{target}」之前$', (p) async {
    // ReorderableListView 拖曳需**分段移動**（單次 dragFrom 會提早落下）；
    // 且拖曳中列表會即時重排——位置預估會漂移，故**重試**（每次多超出 40px）。
    final handle = find.byKey(Key('cat-drag-${p['name']}'));
    final target = find.text(p['target']!);
    for (var attempt = 0; attempt < 3; attempt++) {
      final aDy = w.tester.getTopLeft(find.text(p['name']!)).dy;
      final bDy = w.tester.getTopLeft(target).dy;
      if (aDy < bDy - 8) return; // 已在目標之前
      final from = w.tester.getCenter(handle);
      final to = w.tester.getCenter(target);
      final overshoot = 40.0 * (attempt + 1);
      final gesture = await w.tester.startGesture(from);
      await w.tester.pump();
      await gesture.moveBy(const Offset(0, -48)); // 觸發拖曳開始（一行高）
      await w.tester.pump();
      final remaining = to.dy - from.dy + 48 - 24 - overshoot;
      const steps = 10;
      for (var i = 1; i <= steps; i++) {
        await gesture.moveBy(Offset(0, remaining / steps));
        await w.tester.pump();
      }
      await gesture.up();
      await w.tester.pumpAndSettle();
    }
    final aDy = w.tester.getTopLeft(find.text(p['name']!)).dy;
    final bDy = w.tester.getTopLeft(target).dy;
    expect(aDy, lessThan(bDy), reason: '拖曳排序生效（FR-B1；重試 3 次）');
  });

  runner.on(r'分類列表「{a}」在「{b}」之前$', (p) {
    final aDy = w.tester.getTopLeft(find.text(p['a']!)).dy;
    final bDy = w.tester.getTopLeft(find.text(p['b']!)).dy;
    expect(aDy, lessThan(bDy), reason: '拖曳排序生效（FR-B1）');
  });

  runner.on(r'回到快記其分類快捷格依序含「{name}」$', (p) async {
    // v3（PM 2026-10-24）：分類欄點選 → 彈窗（左欄＝主類別清單）。
    await _ensureApp(w);
    final navigator =
        w.tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.popUntil((r) => r.isFirst);
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('fab-quick-entry')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('quick-entry-category')));
    await w.tester.pumpAndSettle();
    expect(w.tester.any(find.byKey(Key('picker-main-${p['name']}'))), isTrue,
        reason: '分類彈窗左欄含新增主類別（FR-B1；排序另由分類管理列斷言）');
  });

  runner.on(r'分類「{name}」已有 {n} 筆交易$', (p) async {
    final cat = w.db!
        .categoriesByKind('expense')
        .firstWhere((c) => c.name == p['name']!);
    for (var i = 0; i < int.parse(p['n']!); i++) {
      await DbFixture.seedTx(w.db!,
          id: 'tx-f11-$i',
          kind: 'expense',
          amountMinor: 100,
          accountId: w.db!.allAccounts().first.id,
          category: cat.id,
          occurredAt: DateTime.now().millisecondsSinceEpoch);
    }
  });

  runner.on(r'設定→分類管理→刪除「{name}」$', (p) async {
    await _openSettings(w, subKey: 'settings-categories');
    await w.tester.tap(find.byKey(Key('cat-delete-${p['name']}')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'分類列表仍含「{name}」$', (p) {
    expect(w.tester.any(find.byKey(Key('cat-row-${p['name']}'))), isTrue,
        reason: '被拒絕的刪除不得影響分類');
  });

  runner.on(r'設定→分類管理→新增子分類「{name}」於「{parent}」下$', (p) async {
    await _openSettings(w, subKey: 'settings-categories');
    await w.tester.tap(find.byKey(Key('cat-sub-${p['parent']}')));
    await w.tester.pumpAndSettle();
    await w.tester.enterText(find.byKey(const Key('cat-name')), p['name']!);
    await w.tester.tap(find.byKey(const Key('cat-save')));
    await w.tester.pumpAndSettle();
  });

  // DBG-009：編輯子分類（改名）——即時連動快記。
  // PM 2026-10-24：**子類別無圖示**（跟隨主類別）→ 表單不提供圖示選項。
  runner.on(r'設定→分類管理→編輯子分類「{name}」改名「{to}」$', (p) async {
    await w.tester.tap(find.byKey(Key('cat-edit-${p['name']}')));
    await w.tester.pumpAndSettle();
    expect(w.tester.any(find.text('編輯子分類')), isTrue, reason: '編輯模式標題');
    expect(find.text('圖示跟隨主類別（子類別不另設圖示）'), findsOneWidget,
        reason: '子類別無圖示（PM 2026-10-24）');
    await w.tester.enterText(find.byKey(const Key('cat-name')), p['to']!);
    await w.tester.pump();
    await w.tester.tap(find.byKey(const Key('cat-save')));
    await w.tester.pumpAndSettle();
  });

  runner.on(
      r'快記分類選擇器展開「{parent}」後「{name}」項顯示且無圖示$', (p) async {
    await _ensureApp(w);
    final navigator =
        w.tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.popUntil((r) => r.isFirst);
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('fab-quick-entry')));
    await w.tester.pumpAndSettle();
    // v3：分類欄 → 彈窗 → 左欄主類別 → 右欄子類別項（DBG-009 快取失效連動）。
    await w.tester.tap(find.byKey(const Key('quick-entry-category')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(Key('picker-main-${p['parent']}')));
    await w.tester.pumpAndSettle();
    final chip = find.byKey(Key('picker-sub-${p['name']}'));
    expect(w.tester.any(chip), isTrue, reason: '子分類項存在（改名已連動）');
    // 子類別無圖示（PM 2026-10-24）：label 即名稱、不含 emoji。
    expect(
        find.descendant(of: chip, matching: find.text(p['name']!)),
        findsOneWidget,
        reason: 'DBG-009：改名即時連動快記，且子類別**無圖示**');
  });

  runner.on(r'分類列表「{parent}」展開顯示子分類「{name}」$', (p) {
    expect(w.tester.any(find.byKey(Key('cat-sub-row-${p['name']}'))), isTrue,
        reason: '子分類展開（FR-B1 一層）');
  });

  runner.on(r'記帳分類選擇器可選「{name}」$', (p) async {
    await _ensureApp(w);
    final navigator =
        w.tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.popUntil((r) => r.isFirst);
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('fab-quick-entry')));
    await w.tester.pumpAndSettle();
    // v3：分類欄 → 彈窗 → 左欄主類別 → 右欄子類別可選。
    await w.tester.tap(find.byKey(const Key('quick-entry-category')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('picker-main-餐飲食品')));
    await w.tester.pumpAndSettle();
    final subItem = find.byKey(Key('picker-sub-${p['name']}'));
    await w.tester.ensureVisible(subItem);
    await w.tester.pumpAndSettle();
    await w.tester.tap(subItem);
    await w.tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byKey(const Key('quick-entry-category')),
            matching: find.textContaining(p['name']!)),
        findsOneWidget,
        reason: '子分類可選（顯示於分類欄；FR-B1 一層）');
  });

  // ── 子分類拖曳（PM 2026-10-22：子分類也可拖曳）──────────
  runner.on(r'將子分類「{name}」拖曳至子分類「{target}」之前$', (p) async {
    // 群組內嵌清單拖曳——同主類別：分段移動＋重試（超出補償）。
    final handle = find.byKey(Key('cat-sub-drag-${p['name']}'));
    final target = find.text(p['target']!);
    for (var attempt = 0; attempt < 3; attempt++) {
      final aDy = w.tester.getTopLeft(find.text(p['name']!)).dy;
      final bDy = w.tester.getTopLeft(target).dy;
      if (aDy < bDy - 8) return;
      final from = w.tester.getCenter(handle);
      final to = w.tester.getCenter(target);
      final overshoot = 24.0 * (attempt + 1);
      final gesture = await w.tester.startGesture(from);
      await w.tester.pump();
      await gesture.moveBy(const Offset(0, -24));
      await w.tester.pump();
      final remaining = to.dy - from.dy + 24 - 12 - overshoot;
      const steps = 8;
      for (var i = 1; i <= steps; i++) {
        await gesture.moveBy(Offset(0, remaining / steps));
        await w.tester.pump();
      }
      await gesture.up();
      await w.tester.pumpAndSettle();
    }
    final aDy = w.tester.getTopLeft(find.text(p['name']!)).dy;
    final bDy = w.tester.getTopLeft(target).dy;
    expect(aDy, lessThan(bDy), reason: '子分類拖曳排序生效（FR-B1；重試 3 次）');
  });

  runner.on(r'子分類列表「{a}」在「{b}」之前$', (p) {
    final aDy = w.tester.getTopLeft(find.text(p['a']!)).dy;
    final bDy = w.tester.getTopLeft(find.text(p['b']!)).dy;
    expect(aDy, lessThan(bDy), reason: '子分類排序（FR-B1）');
  });

  // ── 常用類別區（PM 2026-10-22：最近使用 10 個常駐最上方）──
  runner.on(r'已有 {n} 筆支出分別使用「{a}」與「{b}」$', (p) async {
    // 最新一筆用 {b}（MRU 第一位＝{b}）；{a} 較舊。
    final catA = w.db!
        .categoriesByKind('expense')
        .firstWhere((c) => c.name == p['a']!);
    final catB = w.db!
        .categoriesByKind('expense')
        .firstWhere((c) => c.name == p['b']!);
    final now = DateTime.now().millisecondsSinceEpoch;
    await DbFixture.seedTx(w.db!,
        id: 'tx-mru-1',
        kind: 'expense',
        amountMinor: 100,
        accountId: w.db!.allAccounts().first.id,
        category: catA.id,
        occurredAt: now - 3600000);
    await DbFixture.seedTx(w.db!,
        id: 'tx-mru-2',
        kind: 'expense',
        amountMinor: 200,
        accountId: w.db!.allAccounts().first.id,
        category: catB.id,
        occurredAt: now);
    // 直寫 db——刷新 ledger 衍生值（recentCategoryIdsProvider 來源）。
    w.container?.invalidate(ledgerProvider);
  });

  runner.on(r'開啟快記並展開分類選擇器$', (p) async {
    await _ensureApp(w);
    final navigator =
        w.tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.popUntil((r) => r.isFirst);
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('fab-quick-entry')));
    await w.tester.pumpAndSettle();
    // v3：點分類欄 → 開啟選擇彈窗（上常用／左主類別／右子類別）。
    await w.tester.tap(find.byKey(const Key('quick-entry-category')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'選單最上方為「{label}」且「{name}」出現於常用區（在完整清單之前）$',
      (p) {
    expect(find.text(p['label']!), findsOneWidget, reason: '常用區標題');
    // v3 彈窗：常用區 key picker-recent-{name}——find.text 全樹搜尋會誤中主殼
    // IndexedStack 交易列（f02 教訓），改以 key 精準定位。
    final recent = find.byKey(Key('picker-freq-${p['name']}'));
    expect(w.tester.any(recent), isTrue,
        reason: '常用區含「${p['name']}」（FR-B1 常用區）');
    // 「在完整清單之前」：常用區 dy < 左欄主類別 dy。
    final aDy = w.tester.getTopLeft(recent).dy;
    final bDy = w.tester
        .getTopLeft(find.byKey(const Key('picker-main-餐飲食品')))
        .dy;
    expect(aDy, lessThan(bDy), reason: '常用區在完整清單之前');
  });

  runner.on(r'於選擇器點「＋ 新增分類」$', (p) async {
    // v3（PM 2026-10-24）：彈窗左欄「＋ 新增主類別」→ 即建即選對話框。
    await w.tester.tap(find.byKey(const Key('picker-add-main')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'顯示「新增主類別」對話框$', (p) {
    expect(w.tester.any(find.byKey(const Key('quick-add-category-name'))), isTrue,
        reason: 'UI-P4：＋主類別 → 即建即選對話框');
  });

  // ── 外觀 ────────────────────────────────────────────────
  runner.on(r'設定→外觀→選擇「{label}」$', (p) async {
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('app-settings')));
    await w.tester.pumpAndSettle();
    final key = switch (p['label']) {
      '淺色' => 'theme-light',
      '深色' => 'theme-dark',
      _ => 'theme-system',
    };
    await w.tester.tap(find.byKey(Key(key)));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'介面立即以深色呈現（AppTokens 深色組）$', (p) {
    final app = w.tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark, reason: 'FR-O1 立即套用');
    expect(app.darkTheme?.scaffoldBackgroundColor, AppTokens.dark.bg,
        reason: '深色組（AppTokens）');
  });

  runner.on(r'關閉並重新啟動 App$', (p) async {
    // 持久化：dispose container → 關檔 → 同檔重開 → 新 container（檔案 DB）。
    w.container?.dispose();
    w.container = null;
    w.db!.close();
    final path = '${w.dir!.path}/ledger.db';
    final reopened = AppDatabase.open(path);
    w.db = reopened;
    w.pumped = false;
    await _ensureApp(w);
  });

  runner.on(r'外觀仍為「{label}」$', (p) {
    final app = w.tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark,
        reason: '外觀持久化（settings app.theme_mode；FR-O1）');
  });
}
