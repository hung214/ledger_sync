import 'dart:convert';
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/sync/sync_fe_state.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/presentation/app_root.dart';
import 'package:ledger_sync/presentation/screens/settings/settings_hub_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// F13 首次啟動引導＋App 內使用說明：
/// ①全新帳本 → 引導三選項 ②**既有使用者不受影響**（有交易直接進主殼）
/// ③還原路徑 ④使用說明頁。清空資料會清 settings → 引導重現（F09 承諾）。
void main() {
  testWidgets('全新帳本：引導三選項 →「全新開始」→ 主殼＋旗標寫入', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = _container(db);
    await _pump(tester, container);

    expect(find.byKey(const Key('guide-start-fresh')), findsOneWidget);
    expect(find.byKey(const Key('guide-restore')), findsOneWidget);
    expect(find.byKey(const Key('guide-import')), findsOneWidget);

    await tester.tap(find.byKey(const Key('guide-start-fresh')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('fab-quick-entry')), findsOneWidget,
        reason: '引導完成 → 主殼');
    expect(db.getSetting('app.onboarded'), '1');
  });

  testWidgets('既有使用者（已有交易）：直接進主殼，不出現引導', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    db.select(
        "INSERT INTO accounts (id,type,name,currency,opening_amount_minor,"
        "archived,created_at,updated_at,hlc) VALUES ('a-1','cash','現金','TWD',0,0,1,1,'0.t')");
    db.select(
        "INSERT INTO transactions (id,kind,amount_minor,currency,account_id,"
        "occurred_at,source,settlement_status,created_at,updated_at,hlc) "
        "VALUES ('t-1','expense',100,'TWD','a-1',1760000000000,'manual','none',1,1,'0.t')");
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = _container(db);
    await _pump(tester, container);

    expect(find.byKey(const Key('guide-start-fresh')), findsNothing,
        reason: '既有使用者不被引導打擾');
    expect(find.byKey(const Key('fab-quick-entry')), findsOneWidget);
  });

  testWidgets('引導 →「從其他 App 匯入」→ 開啟匯入頁 → 返回 → 完成引導', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = _container(db);
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('guide-import')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dm-import-pick')), findsOneWidget);

    await tester.pageBack(); // 返回＝完成引導（主殼內仍可再匯入）
    await tester.pumpAndSettle();
    expect(db.getSetting('app.onboarded'), '1');
    expect(find.byKey(const Key('fab-quick-entry')), findsOneWidget);
  });

  testWidgets('引導 →「從備份檔還原」→ 還原成功進主殼（資料回來）', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    // 先造一份含 1 筆交易的備份檔
    final seedDb = DbFixture.create();
    addTearDown(seedDb.close);
    seedDb.select(
        "INSERT INTO accounts (id,type,name,currency,opening_amount_minor,"
        "archived,created_at,updated_at,hlc) VALUES ('a-1','cash','現金','TWD',0,0,1,1,'0.t')");
    seedDb.select(
        "INSERT INTO transactions (id,kind,amount_minor,currency,account_id,"
        "occurred_at,source,settlement_status,created_at,updated_at,hlc) "
        "VALUES ('t-1','expense',5000,'TWD','a-1',1760000000000,'manual','none',1,1,'0.t')");
    final tmp = Directory.systemTemp.createTempSync('ledger_guide');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final backupPath = '${tmp.path}/backup.db';
    // 產生備份檔：用另一個 AppDatabase 的 snapshot 落檔（與 BackupService.encode 同格式）
    final backupDb = DbFixture.create();
    addTearDown(backupDb.close);
    // 直接以 raw SQL 於 seedDb 匯出 json——此處用最簡方式：sqlite3 backup via select
    // 為避免繞路，改用 BackupService 的 encode 需要 cloud；此處僅驗 UI 流程：
    // fake 開檔回傳「先寫好的快照檔」——由 seedDb 手工組快照。
    final snap = {
      'schema_ver': db.schemaVersion,
      'created_at': 1,
      'accounts': [
        {
          'id': 'a-1', 'type': 'cash', 'name': '現金', 'currency': 'TWD',
          'opening_amount_minor': 0, 'include_in_totals': 1, 'archived': 0,
          'created_at': 1, 'updated_at': 1, 'hlc': '0.t',
        }
      ],
      'transactions': [
        {
          'id': 't-1', 'kind': 'expense', 'amount_minor': 5000, 'currency': 'TWD',
          'account_id': 'a-1', 'occurred_at': 1760000000000, 'source': 'manual',
          'settlement_status': 'none', 'created_at': 1, 'updated_at': 1, 'hlc': '0.t',
        }
      ],
    };
    File(backupPath).writeAsStringSync(
        '\x00${jsonEncode(snap)}', mode: FileMode.write); // flag=0 明文

    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    FileSelectorPlatform.instance =
        _FakePick(XFile(backupPath));
    final container = _container(db);
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('guide-restore')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const Key('guide-restore-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
        db.select('SELECT COUNT(*) c FROM transactions').first['c'], 1,
        reason: '備份內容還原進來');
    expect(db.getSetting('app.onboarded'), '1');
    expect(find.byKey(const Key('fab-quick-entry')), findsOneWidget);
  });

  testWidgets('App 內使用說明：設定 hub 入口 → 說明頁渲染', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = _container(db);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const SettingsHubPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-help')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-help')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('help-page')), findsOneWidget);
    expect(find.textContaining('資料安全'), findsWidgets);
  });
}

ProviderContainer _container(AppDatabase db) {
  return ProviderContainer(overrides: [
    dbProvider.overrideWithValue(db),
    cloudAdapterProvider.overrideWithValue(InMemoryCloudAdapter()),
    syncCoordinatorProvider.overrideWithValue(
        SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
  ]);
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
        theme: buildAppTheme(Brightness.light), home: const AppRootProbe()),
  ));
  await tester.pumpAndSettle();
}

/// 測試用：以固定 db 建構 AppRoot（生產由 main() 建構）。
class AppRootProbe extends StatelessWidget {
  const AppRootProbe({super.key});

  @override
  Widget build(BuildContext context) {
    final db = ProviderScope.containerOf(context).read(dbProvider);
    return AppRoot(db: db);
  }
}

class _FakePick extends FileSelectorPlatform {
  _FakePick(this.file);

  final XFile file;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async =>
      file;
}
