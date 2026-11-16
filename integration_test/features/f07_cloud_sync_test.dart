import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/sync/sync_fe_state.dart';
import 'package:ledger_sync/application/sync/backup_service.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/platform/cloud/cloud_storage_adapter.dart';
import 'package:ledger_sync/presentation/app_shell.dart';
import 'package:ledger_sync/presentation/screens/settings/settings_sync_page.dart';

import '../../test/helpers/db_fixture.dart';
import '../../test/helpers/gherkin/gherkin.dart';
import '../../test/helpers/harness_robust.dart';
import '../../test/helpers/in_memory_cloud_adapter.dart';

/// F07-FE 情境執行器（@FE @M5 @FR-Y，6 情境：連結授權/立即同步/啟動自動
/// 同步/新裝置還原/異帳號/衝突檢視）。
///
/// 來源：specs/plan/tests/frontend/F07_cloud-sync-backup.feature（rootBundle）。
/// 句型登記簿：specs/plan/tests/dsl.md §3（v0.9）。
/// OAuth/雲端為平台層——FE 以 fake seam 驗 UI 流程（帳號空間 adapter：
/// 依登入 email 路由不同檔案空間，異帳號語意）。
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final doc = GherkinParser.parse(await rootBundle
      .loadString('integration_test/features/F07_cloud-sync-backup.feature'));

  testWidgets('F07-FE：雲端同步 UI（6 情境）', (tester) async {
    final w = _World(tester);
    final runner = GherkinRunner();
    _bind(runner, w);
    try {
      final executed = await runner.run(doc, tagFilter: (tags) => tags.contains('@FE'));
      expect(executed, 6, reason: 'F07-FE 應執行 6 個情境');
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

/// 帳號空間 adapter（依 currentEmail 路由檔案空間——異帳號語意）。
class _AccountScopedAdapter implements CloudStorageAdapter {
  final Map<String, InMemoryCloudAdapter> _spaces = {};
  String currentEmail = 'ming@example.com';

  InMemoryCloudAdapter get _space =>
      _spaces.putIfAbsent(currentEmail, InMemoryCloudAdapter.new);

  InMemoryCloudAdapter spaceOf(String email) =>
      _spaces.putIfAbsent(email, InMemoryCloudAdapter.new);

  /// 節流（5ms/操作）：模擬網路延遲——「同步中…」回饋的時序窗（tap 後
  /// pump() 未 settle 斷言需要 sync 尚未完成；fake 立即 resolve 會一閃即逝）。
  Future<void> _pace() => Future.delayed(const Duration(milliseconds: 5));

  @override
  Future<bool> isConfigured() async => true;

  @override
  Future<List<String>> list(String folder) async {
    await _pace();
    return _space.list(folder);
  }

  @override
  Future<void> upload(String path, Uint8List bytes) async {
    await _pace();
    await _space.upload(path, bytes);
  }

  @override
  Future<Uint8List?> download(String path) async {
    await _pace();
    return _space.download(path);
  }

  @override
  Future<void> delete(String path) async {
    await _pace();
    await _space.delete(path);
  }
}

class _World {
  _World(this.tester);

  final WidgetTester tester;
  final List<AppDatabase> dbs = [];
  final List<ProviderContainer> containers = [];
  AppDatabase? db;
  ProviderContainer? container;
  bool pumped = false;
  final _AccountScopedAdapter scopedCloud = _AccountScopedAdapter();

  /// fake OAuth 回傳（情境切換：ming@example.com／other@example.com）。
  String oauthEmail = 'ming@example.com';
}

void _bind(GherkinRunner runner, _World w) {
  // ── Background ───────────────────────────────────────────
  runner.on(r'App 已完成首次設定$', (p) {
    final db = DbFixture.create();
    w.dbs.add(db);
    w.db = db;
    w.pumped = false;
    w.oauthEmail = 'ming@example.com';
    w.scopedCloud.currentEmail = 'ming@example.com';
  });

  runner.on(r'模擬雲端為 in-memory adapter 且已連結（Google 帳號 {email}）$', (p) {
    w.oauthEmail = p['email']!;
    w.scopedCloud.currentEmail = p['email']!;
    // 已連結語意：settings 落帳號（pump 後 syncAccountProvider 讀取；
    // 啟動同步鉤子據此觸發）。
    w.db!.setSetting('sync.account', p['email']!);
  });

  // ── Given ────────────────────────────────────────────────
  runner.on(r'未連結雲端$', (p) async {
    await _ensureApp(w);
    w.container!.read(syncAccountProvider.notifier).unlink();
    await w.tester.pumpAndSettle();
  });

  runner.on(r'已有 {n} 筆未同步變更$', (p) async {
    await _ensureApp(w);
    if (w.db!.allAccounts().isEmpty) {
      // 情境無「已建立帳戶」步驟——本地背景帳戶（同 M5 BE ensureDevice 慣例）。
      DbFixture.seedAccount(w.db!,
          id: 'a-0', type: 'cash', name: '現金', opening: 1000);
    }
    final n = int.parse(p['n']!);
    for (var i = 0; i < n; i++) {
      await DbFixture.seedTx(w.db!,
          id: 'tx-pending-$i',
          kind: 'expense',
          amountMinor: 100 * (i + 1),
          accountId: w.db!.allAccounts().first.id,
          occurredAt: Clock.now().millisecondsSinceEpoch);
      // seedTx 已含 oplog 整列快照（packed_seq=null）——勿重複 append。
    }
    w.container!.read(pendingOpsProvider.notifier).refresh();
    await w.tester.pumpAndSettle();
  });

  runner.on(r'模擬雲端已有帳本資料$', (p) async {
    await _ensureApp(w);
    await _seedCloudData(w, 'ming@example.com');
  });

  runner.on(r'模擬雲端已有帳本資料（帳號 {email}）$', (p) async {
    await _ensureApp(w);
    await _seedCloudData(w, p['email']!);
  });

  runner.on(r'同步狀態頁有 {n} 筆衝突事件（被覆蓋內容「{text}」）$', (p) async {
    // 本情境須先 pump（Background 已換新 db／pumped=false——未 pump 則
    // container 為前一情境殘留、樹也停在舊頁）。
    await _ensureApp(w);
    final db = w.db!;
    final n = int.parse(p['n']!);
    for (var i = 0; i < n; i++) {
      db.insertSyncEvent(SyncEventRow(
        id: 'se-$i',
        entity: 'transactions',
        entityId: 'tx-X',
        incomingHlc: '1792549264000.00001.d-B',
        overwrittenRow: jsonEncode({
          'id': 'tx-X',
          'kind': 'expense',
          'amount_minor': 120,
          'note': p['text'],
        }),
        createdAt: Clock.now().millisecondsSinceEpoch,
      ));
    }
    w.container!.read(syncEventsProvider.notifier).refresh();
    await w.tester.pumpAndSettle();
  });

  // ── When：導航與互動 ─────────────────────────────────────
  runner.on(r'設定→雲端與同步→按下「連結 Google Drive」$', (p) async {
    await _ensureApp(w);
    await _openSettingsSync(w);
    await _tapUntil(w, find.byKey(const Key('sync-link')),
        () => w.tester.any(find.byKey(const Key('google-signin'))));
  });

  runner.on(r'完成登入並同意授權$', (p) async {
    // fake OAuth 畫面：同意授權鈕（oauthProvider seam 回 email）。
    await _tapUntil(w, find.byKey(const Key('oauth-approve')),
        () =>
            w.tester.any(find.text('連結成功')) ||
            w.tester.any(find.byKey(const Key('sync-now'))));
  });

  runner.on(r'按下「立即同步」$', (p) async {
    await _openSettingsSync(w); // 已連結→同步操作區
    await w.tester.tap(find.byKey(const Key('sync-now')));
    await w.tester.pump(); // 渲染「同步中…」frame（未 settle）
  });

  runner.on(r'關閉並重新啟動 App$', (p) async {
    // 同 db 重建（未同步變更留 oplog）＋啟動同步鉤子（FR-Y11）。
    // 凍結「今天 09:00」：last_at 落於此時刻（acceptance S3 顯示契約）。
    final now = Clock.now();
    final frozen = DateTime(now.year, now.month, now.day, 9, 0);
    Clock.freeze(frozen);
    w.pumped = false;
    await _ensureApp(w);
  });

  runner.on(r'關閉並重新啟動 App 並選擇「從雲端還原」$', (p) async {
    w.pumped = false;
    await _ensureApp(w);
    await _openSettingsSync(w);
    // 還原第一步（S7.4 #1）：導向 Google 登入。
    await _tapUntil(w, find.byKey(const Key('restore-cloud')),
        () => w.tester.any(find.byKey(const Key('google-signin'))));
  });

  runner.on(r'登入同一帳號$', (p) async {
    // 還原第二步（S7.4 #2）：bootstrap → 結果回饋。
    await _tapUntil(w, find.byKey(const Key('oauth-approve')),
        () => w.tester.any(find.text('還原完成')) ||
            w.tester.any(find.text('此帳號沒有可還原的資料')));
  });

  runner.on(r'選擇「從雲端還原」並登入帳號 {email}$', (p) async {
    w.oauthEmail = p['email']!;
    w.scopedCloud.currentEmail = p['email']!;
    // Given 僅預置雲端資料（停在主殼）——本步語意為在同步設定頁操作，
    // 故先導航（等價驅動；原型 harness 遺漏此步＝S5 未驗之因）。
    await _openSettingsSync(w);
    await _tapUntil(w, find.byKey(const Key('restore-cloud')),
        () => w.tester.any(find.byKey(const Key('google-signin'))));
    await _tapUntil(w, find.byKey(const Key('oauth-approve')),
        () => w.tester.any(find.text('還原完成')) ||
            w.tester.any(find.text('此帳號沒有可還原的資料')));
  });

  runner.on(r'開啟同步狀態頁$', (p) async {
    await _ensureApp(w); // 本情境須先 pump（同 Given 說明）
    await _openSettingsSync(w);
    await _tapUntil(w, find.byKey(const Key('sync-conflicts-entry')),
        () => w.tester.any(find.byKey(const Key('conflict-view-0'))));
  });

  runner.on(r'按下檢視$', (p) async {
    // 衝突列為唯讀快照（無導航）；此步確保列可見（Then 斷言內容）。
    await _tapUntil(w, find.byKey(const Key('conflict-view-0')).first,
        () => w.tester.any(find.byKey(const Key('conflict-view-0'))));
  });

  // ── Then ─────────────────────────────────────────────────
  runner.on(r'顯示「Google 登入」（模擬）$', (p) {
    expect(w.tester.any(find.byKey(const Key('google-signin'))), isTrue,
        reason: 'FR-Y7：OAuth seam 登入畫面');
  });

  runner.on(r'顯示「連結成功」$', (p) {
    expect(w.tester.any(find.text('連結成功')), isTrue, reason: 'FR-Y7 授權完成');
  });

  runner.on(r'顯示「同步中…」$', (p) async {
    expect(w.tester.any(find.text('同步中…')), isTrue, reason: 'FR-Y11 進行中回饋');
    // 等待同步完成（僅同步步驟；bounded——避免節流下無限等待）。
    for (var i = 0; i < 25; i++) {
      if (w.tester.any(find.byKey(const Key('sync-result')))) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await w.tester.pump(const Duration(milliseconds: 100));
    }
  });

  runner.on(r'顯示「已同步 {n} 筆變更」$', (p) {
    expect(w.tester.any(find.text('已同步 ${p['n']!} 筆變更')), isTrue,
        reason: 'FR-Y11 完成回饋');
  });

  runner.on(r'顯示「待同步 {n} 筆」$', (p) {
    expect(w.tester.any(find.text('待同步 ${p['n']!} 筆')), isTrue,
        reason: 'FR-Y11 待同步計數');
  });

  runner.on(r'顯示「上次同步 今天 {time}」$', (p) async {
    // 「上次同步」呈現於設定同步頁——重啟後在主殼，須先開頁。
    if (w.tester.any(find.byType(SettingsSyncPage)) != true) {
      await _openSettingsSync(w);
    }
    expect(w.tester.any(find.text('上次同步 今天 ${p['time']!}')), isTrue,
        reason: 'FR-Y11 啟動同步觸發（last_at 格式化）');
  });

  runner.on(r'顯示「還原完成」（帳戶/交易/分類/預算）$', (p) {
    expect(w.tester.any(find.text('還原完成')), isTrue, reason: 'AC-08 還原結果');
  });

  runner.on(r'顯示「此帳號沒有可還原的資料」$', (p) {
    expect(w.tester.any(find.text('此帳號沒有可還原的資料')), isTrue,
        reason: 'FR-Y2：異帳號空空間');
  });

  runner.on(r'顯示「{n} 筆衝突」$', (p) {
    expect(w.tester.any(find.text('${p['n']!} 筆衝突')), isTrue,
        reason: 'AC-07 衝突計數');
  });

  runner.on(r'顯示「{text}」（唯讀）$', (p) {
    expect(w.tester.any(find.text(p['text']!, skipOffstage: false)), isTrue,
        reason: 'FR-Y5 被覆蓋內容唯讀檢視');
  });

  runner.on(r'不顯示「{text}」$', (p) {
    expect(w.tester.any(find.text(p['text']!, skipOffstage: false)), isFalse,
        reason: '反斷言：不應顯示「${p['text']}」');
  });

  runner.on(r'顯示「{text}」$', (p) {
    expect(w.tester.any(find.text(p['text']!, skipOffstage: false)), isTrue,
        reason: '應顯示「${p['text']}」');
  });
}

// ── 輔助 ─────────────────────────────────────────────

Future<void> _ensureApp(_World w) async {
  if (w.pumped) return;
  final db = w.db!;
  final container = ProviderContainer(overrides: [
    dbProvider.overrideWithValue(db),
    cloudAdapterProvider.overrideWithValue(w.scopedCloud),
    oauthProvider.overrideWithValue(() async => w.oauthEmail),
    syncCoordinatorProvider.overrideWithValue(
      SyncCoordinator(db, w.scopedCloud, deviceId: 'd-A', blobs: null,
          onConflictEvent: (_) {
        w.container?.read(syncEventsProvider.notifier).refresh();
      }),
    ),
  ]);
  w.containers.add(container);
  w.container = container;
  await w.tester.pumpWidget(
    KeyedSubtree(
      // key 帶 container 序數：同情境內「關閉並重新啟動」（S3）時 dbs 不變，
      // 須強制重建以重跑 initState 啟動鉤子（DBG-007 教訓）。
      key: ValueKey('app-shell-${w.containers.length}'),
      child: UncontrolledProviderScope(container: container, child: const AppShell()),
    ),
  );
  await w.tester.pumpAndSettle();
  w.pumped = true;
  // FR-Y11 啟動同步：已連結時同步一次（與 MainShellPage 啟動鉤子同語意——
  // 測試以明確呼叫確保時序確定性）。
  if ((db.getSetting('sync.account') ?? '').isNotEmpty) {
    await container.read(syncCoordinatorProvider).sync();
    afterSyncRefresh(container);
    await w.tester.pumpAndSettle();
  }
}

/// 穩健 tap——共用實作見 `test/helpers/harness_robust.dart`（DBG-007 教訓：
/// macOS 遮擋節流致 frame 陳舊→tap 落空）。本檔保留薄包裝以免動 8 處呼叫點。
Future<void> _tapUntil(_World w, Finder f, bool Function() until,
        {int retries = 12}) =>
    tapUntil(w.tester, f, until, retries: retries);

Future<void> _openSettingsSync(_World w) async {
  await w.tester.tap(find.byKey(const Key('app-settings')));
  await w.tester.pumpAndSettle();
  // M7 設定入口已恢復為 Hub（SettingsHubPage）——補一步「雲端同步」。
  await w.tester.tap(find.byKey(const Key('settings-sync')));
  await w.tester.pumpAndSettle();
  expect(w.tester.any(find.byType(SettingsSyncPage)), isTrue,
      reason: '設定同步頁應已開啟');
}

/// 預置雲端帳本資料（bundle＋backup 於指定帳號空間）。
Future<void> _seedCloudData(_World w, String email) async {
  final space = w.scopedCloud.spaceOf(email);
  final srcDb = DbFixture.create();
  w.dbs.add(srcDb);
  DbFixture.seedAccount(srcDb, id: 'a-src', type: 'cash', name: '現金', opening: 1000);
  DbFixture.seedCategory(srcDb, id: 'c-src', kind: 'expense', name: '餐飲食品');
  await DbFixture.seedTx(srcDb,
      id: 'tx-cloud',
      kind: 'expense',
      amountMinor: 195,
      accountId: 'a-src',
      category: 'c-src',
      merchant: '雲端商家',
      occurredAt: Clock.now().millisecondsSinceEpoch);
  final coordinator = SyncCoordinator(srcDb, space, deviceId: 'd-src');
  await coordinator.sync();
  await BackupService(srcDb, space, deviceId: 'd-src').runIfNeeded();
  srcDb.close();
}
