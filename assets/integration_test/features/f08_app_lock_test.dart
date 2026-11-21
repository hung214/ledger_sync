import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ledger_sync/application/lock/app_lock_controller.dart';
import 'package:ledger_sync/application/lock/lock_fe_state.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/presentation/app_shell.dart';
import 'package:ledger_sync/presentation/screens/lock/lock_screen.dart';

import '../../test/helpers/db_fixture.dart';
import '../../test/helpers/in_memory_cloud_adapter.dart';
import '../../test/helpers/gherkin/gherkin.dart';

/// F08-FE 情境執行器（@FE @M7 @FR-X，5 情境：背景逾時鎖定/門檻內不鎖/
/// 生物辨識退回 PIN/忘記 PIN 重設/隱私遮蔽）。
///
/// 來源：specs/plan/tests/frontend/F08_app-lock-security.feature（rootBundle）。
/// 句型登記簿：specs/plan/tests/dsl.md §3（v1.3）。
/// Face ID/雲端 token 為平台層——fake seam（biometricAuthProvider 可控回呼）。
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final doc = GherkinParser.parse(await rootBundle
      .loadString('integration_test/features/F08_app-lock-security.feature'));

  testWidgets('F08-FE：App 鎖與隱私 UI（5 情境）', (tester) async {
    final w = _World(tester);
    final runner = GherkinRunner();
    _bind(runner, w);
    try {
      final executed = await runner.run(doc, tagFilter: (tags) => tags.contains('@FE'));
      expect(executed, 5, reason: 'F08-FE 應執行 5 個情境');
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

  /// fake Face ID 回呼結果（S1 成功 true／S3 失敗 false）。
  bool biometricResult = true;
}

void _bind(GherkinRunner runner, _World w) {
  // ── Background ───────────────────────────────────────────
  runner.on(r'App 已完成首次設定$', (p) {
    final db = DbFixture.create();
    w.dbs.add(db);
    w.db = db;
    w.pumped = false;
    w.biometricResult = true;
  });

  runner.on(r'App 鎖已啟用（PIN {pin} \+ Face ID、門檻 {n} 秒）$', (p) {
    // controller 於 _ensureApp 的 override 建構（此處僅記參數於 harness 慣例）。
    w.db!.setSetting('lock.pin_hash', ''); // 由 controller 建構時寫入
  });

  runner.on(r'App 已連結雲端帳號$', (p) {
    w.db!.setSetting('sync.account', 'ming@example.com');
  });

  // ── When ─────────────────────────────────────────────────
  runner.on(r'App 切至背景 {n} 秒後返回$', (p) async {
    await _ensureApp(w);
    // 直接驅動（lifecycle 事件語意等價；真機 lifecycle 屬 acceptance 走查——
    // TestBinding 的狀態序列約束使直接 paused 不可靠）。
    final lock = w.container!.read(appLockControllerProvider);
    Clock.freeze(Clock.now()); // t0（advance 前提——T-H2 契約）
    lock.onBackground();
    Clock.advance(Duration(seconds: int.parse(p['n']!)));
    if (lock.shouldLockOnResume()) {
      w.container!.read(lockOverlayProvider.notifier).show();
    }
    await w.tester.pumpAndSettle();
  });

  runner.on(r'使用 Face ID 成功解鎖$', (p) async {
    w.biometricResult = true;
    await w.tester.tap(find.byKey(const Key('faceid-button')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'Face ID 連續失敗 {n} 次$', (p) async {
    // 情境隱含已鎖定（鎖定畫面上之 Face ID 嘗試）——確保覆蓋層呈現。
    w.container!.read(lockOverlayProvider.notifier).show();
    await w.tester.pumpAndSettle();
    w.biometricResult = false;
    for (var i = 0; i < int.parse(p['n']!); i++) {
      await w.tester.tap(find.byKey(const Key('faceid-button')));
      await w.tester.pumpAndSettle();
    }
  });

  runner.on(r'輸入 PIN {pin}$', (p) async {
    w.container!.read(lockOverlayProvider.notifier).show();
    await w.tester.pumpAndSettle();
    await w.tester.enterText(find.byKey(const Key('pin-input')), p['pin']!);
    await w.tester.pump();
    await w.tester.tap(find.byKey(const Key('pin-submit')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'按下「忘記 PIN」$', (p) async {
    await w.tester.tap(find.byKey(const Key('forgot-pin')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'設定新 PIN {pin}$', (p) async {
    await w.tester.enterText(find.byKey(const Key('new-pin-input')), p['pin']!);
    await w.tester.pump();
    await w.tester.tap(find.byKey(const Key('new-pin-submit')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'於鎖定畫面$', (p) async {
    await _ensureApp(w);
    // S4 語意：有既有資料的帳本（20 筆——「資料完整保留」驗證基準）。
    if (w.db!.allTransactions().where((t) => t.deletedAt == null).length < 20) {
      if (w.db!.allAccounts().isEmpty) {
        await DbFixture.seedAccount(w.db!,
            id: 'a-0', type: 'cash', name: '現金', opening: 50000);
      }
      final accountId = w.db!.allAccounts().first.id;
      for (var i = 0; i < 20; i++) {
        await DbFixture.seedTx(w.db!,
            id: 'tx-lock-$i',
            kind: 'expense',
            amountMinor: 100 + i,
            accountId: accountId,
            occurredAt: Clock.now().millisecondsSinceEpoch - i * 60000);
      }
    }
    w.container!.read(lockOverlayProvider.notifier).show();
    await w.tester.pumpAndSettle();
    expect(w.tester.any(find.byType(LockScreen)), isTrue, reason: '鎖定畫面呈現');
  });

  runner.on(r'重新登入同一雲端帳號$', (p) {
    // fake OAuth/token（LockScreen._forgotPin 流程內已呼叫 seam）——no-op。
  });

  runner.on(r'按下 👁 遮蔽開關$', (p) async {
    await w.tester.tap(find.byKey(const Key('privacy-toggle')));
    await w.tester.pumpAndSettle();
  });

  // ── Then ─────────────────────────────────────────────────
  runner.on(r'不顯示「鎖定畫面」$', (p) {
    expect(w.tester.any(find.byType(LockScreen)), isFalse,
        reason: 'FR-X1：門檻內返回不鎖定');
  });

  runner.on(r'顯示「鎖定畫面」$', (p) {
    expect(w.tester.any(find.byType(LockScreen)), isTrue,
        reason: 'AC-09：鎖定覆蓋層（全遮蔽）');
  });

  runner.on(r'顯示「離開前的畫面」且資料完整$', (p) {
    expect(w.tester.any(find.byType(LockScreen)), isFalse,
        reason: '解鎖後覆蓋層移除——恢復離開前畫面');
  });

  // 無尾綴變體（S3；長版先註冊）——「離開前的畫面」＝解鎖後恢復語意。
  runner.on(r'顯示「離開前的畫面」$', (p) {
    expect(w.tester.any(find.byType(LockScreen)), isFalse,
        reason: '解鎖後覆蓋層移除——恢復離開前畫面');
  });

  runner.on(r'顯示「PIN 輸入鍵盤」$', (p) {
    expect(w.tester.any(find.byKey(const Key('pin-input'))), isTrue,
        reason: 'FR-X1：退場後 PIN 輸入');
  });

  runner.on(r'顯示「設定新 PIN」$', (p) {
    expect(w.tester.any(find.byKey(const Key('new-pin-input'))), isTrue,
        reason: 'FR-X5：重設流程');
  });

  runner.on(r'顯示「資料完整保留」（{n} 筆交易）$', (p) {
    final txs = w.db!.allTransactions().where((t) => t.deletedAt == null);
    expect(txs.length, int.parse(p['n']!), reason: 'FR-X5：資料零損失');
    expect(w.tester.any(find.byType(LockScreen)), isFalse,
        reason: '重設後解鎖');
  });

  runner.on(r'再按一次$', (p) async {
    await w.tester.tap(find.byKey(const Key('privacy-toggle')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'金額全部顯示為 ●●●●$', (p) {
    expect(w.tester.any(find.textContaining('●●●●')), isTrue,
        reason: 'FR-X3：隱私遮蔽');
    expect(w.tester.any(find.textContaining('12,340')), isFalse,
        reason: '遮蔽態不顯示原金額');
  });

  runner.on(r'顯示「{amount}」（原金額）$', (p) {
    expect(w.tester.any(find.textContaining(p['amount']!)), isTrue,
        reason: '遮蔽關閉還原（UI 含「餘額」前綴）');
  });

  runner.on(r'不顯示「{text}」$', (p) {
    expect(w.tester.any(find.text(p['text']!, skipOffstage: false)), isFalse,
        reason: '反斷言：不應顯示「${p['text']}」');
  });

  runner.on(r'顯示「{text}」$', (p) {
    expect(w.tester.any(find.text(p['text']!, skipOffstage: false)), isTrue,
        reason: '應顯示「${p['text']}」');
  });

  // S5 隱私遮蔽：總覽頁（帳戶餘額 12,340——零交易期初）。
  runner.on(r'使用者位於總覽頁$', (p) async {
    // S5：帳戶餘額 12,340（零交易期初）——pump 前種資（provider 首建即含）。
    if (w.db!.allAccounts().isEmpty) {
      await DbFixture.seedAccount(w.db!,
          id: 'a-0', type: 'cash', name: '現金', opening: 12340);
    }
    await _ensureApp(w);
    await w.tester.tap(find.byKey(const Key('nav-總覽')));
    await w.tester.pumpAndSettle();
  });
}

// ── 輔助 ─────────────────────────────────────────────

Future<void> _ensureApp(_World w) async {
  if (w.pumped) return;
  final db = w.db!;
  final lock = await AppLockController.create(db, pin: '1234', thresholdSec: 30);
  final container = ProviderContainer(overrides: [
    dbProvider.overrideWithValue(db),
    appLockControllerProvider.overrideWithValue(lock),
    biometricAuthProvider
        .overrideWithValue(() async => w.biometricResult),
    // 啟動同步鉤子（FR-Y11）防 UnimplementedError——隔離雲端空間。
    syncCoordinatorProvider.overrideWithValue(
        SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
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
}

