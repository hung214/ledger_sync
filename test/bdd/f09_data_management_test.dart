import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/sync/backup_service.dart';
import 'package:ledger_sync/application/scan/blob_store_factory.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/application/wipe/wipe_service.dart';
import 'package:ledger_sync/core/hlc.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';

import '../helpers/db_fixture.dart';
import '../helpers/gherkin/gherkin.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// F09-BE 情境執行器（@BE @M7 @FR-O3 @P1，3 情境：未連雲端本地清空/
/// 已連雲端完整清空/清空後其他裝置不復活）。
///
/// 來源：specs/plan/tests/backend/F09_data-management.feature（同步副本）。
/// 句型登記簿：specs/plan/tests/dsl.md §2（v1.4）。
void main() {
  final source = File('test/bdd/F09_data-management.feature').readAsStringSync();
  final doc = GherkinParser.parse(source);

  test('F09-BE：資料清除執行（3 情境）', () async {
    final w = _World();
    final runner = GherkinRunner();
    _bind(runner, w);
    try {
      final executed = await runner.run(doc, tagFilter: (tags) => tags.contains('@BE'));
      expect(executed, 3, reason: 'F09-BE 應執行 3 個情境');
      // ignore: avoid_print
      print(runner.log.join('\n'));
    } finally {
      for (final db in w.dbs) {
        db.close();
      }
      for (final dir in w.tempDirs) {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      }
    }
  });

  /// 回歸（FR-O3 不復活閘）：正式同步路徑 sync()——曾同步過而 vault 缺
  /// → CloudWipedException，不重建 vault、不 push（驗收 S9.2 #5 Critical）。
  test('F09-BE 回歸：sync() 偵測雲端已清空（不復活閘）', () async {
    final db = DbFixture.create();
    final cloud = InMemoryCloudAdapter();
    final blobs = Directory.systemTemp.createTempSync('ledger_blobs_f09_regress');
    final coordinator = SyncCoordinator(db, cloud, deviceId: 'd-A', blobs: newBlobStore(dirPath: blobs.path));
    try {
      DbFixture.seedAccount(db, id: 'a-0', type: 'cash', name: '現金', opening: 1000);
      await DbFixture.seedTx(db,
          id: 't-1', kind: 'expense', amountMinor: 100, accountId: 'a-0', occurredAt: 1000);

      // 首次同步（空雲端 → vault 建置＋push——旗標武裝）。
      await coordinator.sync();
      expect(await cloud.list(''), isNotEmpty);

      // 雲端被清空（另一裝置執行 WipeService 含雲端）。
      for (final path in await cloud.list('')) {
        await cloud.delete(path);
      }

      // 正式路徑 sync()：須拋不復活例外，且不把舊資料推回雲端。
      await expectLater(coordinator.sync(), throwsA(isA<CloudWipedException>()));
      expect(await cloud.list(''), isEmpty,
          reason: '不復活：sync() 偵測雲端已清空後不得 push 舊資料');
    } finally {
      db.close();
      if (blobs.existsSync()) blobs.deleteSync(recursive: true);
    }
  });

  /// 回歸（反向）：首次連結（無 device.ever_synced 旗標）於空雲端 sync()
  /// 不得誤判——_ensureVault 正常建置（新裝置/新帳本路徑）。
  test('F09-BE 回歸：首次連結空雲端不誤判不復活', () async {
    final db = DbFixture.create();
    final cloud = InMemoryCloudAdapter();
    final blobs = Directory.systemTemp.createTempSync('ledger_blobs_f09_first');
    final coordinator = SyncCoordinator(db, cloud, deviceId: 'd-new', blobs: newBlobStore(dirPath: blobs.path));
    try {
      await coordinator.sync(); // 無旗標 → vault 建置，不拋
      expect(await cloud.download('vault.json'), isNotNull);
    } finally {
      db.close();
      if (blobs.existsSync()) blobs.deleteSync(recursive: true);
    }
  });
}

class _World {
  final dbs = <AppDatabase>[];
  final tempDirs = <Directory>[];

  late AppDatabase db;
  late Directory blobsDir;
  late SyncCoordinator coordinatorA;
  InMemoryCloudAdapter cloud = InMemoryCloudAdapter();

  // S3：裝置B（同帳號空間；獨立本地 DB）。
  AppDatabase? dbB;
  Directory? blobsDirB;
  SyncCoordinator? coordinatorB;

  /// S3 捕捉之 pull 例外（顯示「雲端資料已不存在」斷言用）。
  Object? pullError;

  int _tableCount(String table) => db
      .select('SELECT COUNT(*) AS c FROM $table')
      .first['c'] as int;
}

void _bind(GherkinRunner runner, _World w) {
  // ── Background ───────────────────────────────────────────
  runner.on(r'已重置記憶體資料庫$', (p) {
    w.db = DbFixture.create();
    w.dbs.add(w.db);
  });

  runner.on(r'帳本含 {n} 筆交易與 {m} 張附件$', (p) {
    final n = int.parse(p['n']!);
    final m = int.parse(p['m']!);
    DbFixture.seedAccount(w.db, id: 'a-0', type: 'cash', name: '現金', opening: 1000);
    DbFixture.seedCategory(w.db, id: 'c-1', kind: 'expense', name: '餐飲食品');
    for (var i = 1; i <= n; i++) {
      DbFixture.seedTx(w.db,
          id: 't-${i.toString().padLeft(2, '0')}',
          kind: 'expense',
          amountMinor: 100 * i,
          accountId: 'a-0',
          category: 'c-1',
          merchant: '商家$i',
          occurredAt: 1700000000000 + i * 60000);
    }
    // 附件×m：blobs 檔＋attachments 列＋oplog（fixture 直寫——dsl v1.4）。
    for (var j = 1; j <= m; j++) {
      final bytes = Uint8List.fromList(List.generate(64, (i) => i * j));
      final digest = sha256.convert(bytes).toString();
      w.blobsDir = Directory.systemTemp.createTempSync('ledger_blobs_f09');
      w.tempDirs.add(w.blobsDir);
      w.blobsDir.createSync(recursive: true);
      File('${w.blobsDir.path}/$digest').writeAsBytesSync(bytes);
      final hlc = Hlc.now('d-A').toString();
      w.db.insertAttachmentWithOplog(
        AttachmentRow(
          id: 'att-$j',
          transactionId: 't-01',
          sha256: digest,
          mime: 'image/jpeg',
          byteSize: bytes.length,
          createdAt: 1700000000000,
          hlc: hlc,
        ),
        OplogRow(
          entity: 'attachments',
          entityId: 'att-$j',
          hlc: hlc,
          payload: '{}',
          packedSeq: null,
        ),
      );
    }
  });

  runner.on(r'模擬雲端為 in-memory adapter 且已連結$', (p) {
    w.cloud.reset(); // 情境隔離：上一情境之雲端殘留清空
    w.db.setSetting('sync.account', 'ming@example.com');
    w.blobsDir = Directory.systemTemp.createTempSync('ledger_blobs_f09');
    w.tempDirs.add(w.blobsDir);
    w.coordinatorA = SyncCoordinator(w.db, w.cloud, deviceId: 'd-A', blobs: newBlobStore(dirPath: w.blobsDir.path));
  });

  // ── Given（長句型先登記——lazy 前綴碰撞） ─────────────────
  runner.on(r'已連結雲端（雲端含 vault/ops/backups）$', (p) async {
    // 預置雲端佈局：同步一次（vault/devices/ops）＋備份一次（backups）。
    await w.coordinatorA.sync();
    await BackupService(w.db, w.cloud, deviceId: 'd-A').runIfNeeded();
    expect(await w.cloud.list(''), isNotEmpty, reason: '前置：雲端佈局應已存在');
  });

  runner.on(r'已連結雲端且裝置B 存在$', (p) async {
    // 裝置B：同帳號空間，獨立本地 DB（持有 1 筆未同步交易——推回內容非空）。
    final dbB = DbFixture.create();
    w.dbs.add(dbB);
    w.dbB = dbB;
    DbFixture.seedAccount(dbB, id: 'a-b', type: 'cash', name: '現金B', opening: 500);
    await DbFixture.seedTx(dbB,
        id: 't-b1', kind: 'expense', amountMinor: 300, accountId: 'a-b', occurredAt: 1700000099999);
    w.blobsDirB = Directory.systemTemp.createTempSync('ledger_blobs_f09_b');
    w.tempDirs.add(w.blobsDirB!);
    w.coordinatorB = SyncCoordinator(dbB, w.cloud, deviceId: 'd-B', blobs: newBlobStore(dirPath: w.blobsDirB!.path));
    await w.coordinatorB!.sync(); // B 完成一次同步（push ops＋manifest；旗標武裝）
    expect(await w.cloud.list(''), isNotEmpty, reason: '前置：裝置B 應已上傳');
  });

  runner.on(r'未連結雲端$', (p) {
    w.db.setSetting('sync.account', '');
  });

  runner.on(r'雲端資料已清除$', (p) async {
    // 另一裝置執行 WipeService 之雲端段：根清單逐一刪除。
    for (final path in await w.cloud.list('')) {
      await w.cloud.delete(path);
    }
    expect(await w.cloud.list(''), isEmpty, reason: '前置：雲端應已全空');
  });

  // ── When ─────────────────────────────────────────────────
  runner.on(r'執行清空資料（含雲端={flag}，身分驗證通過）$', (p) async {
    // 身分驗證前提（FR-O3/驗收 S9.2——重新登入雲端帳號通過）已由情境敘述成立。
    await WipeService(w.db, cloud: w.cloud, blobs: newBlobStore(dirPath: w.blobsDir.path))
        .wipe(includeCloud: p['flag'] == 'true');
  });

  runner.on(r'執行清空資料（含雲端={flag}）$', (p) async {
    await WipeService(w.db, cloud: w.cloud, blobs: newBlobStore(dirPath: w.blobsDir.path))
        .wipe(includeCloud: p['flag'] == 'true');
  });

  runner.on(r'裝置B 執行 SyncCoordinator.pull 與 push$', (p) async {
    // pull 拋 CloudWipedException → push 不得執行（不復活契約）。
    try {
      await w.coordinatorB!.pull();
      w.pullError = null;
      // pull 未拋（不應發生）——仍不 push：由 Then 斷言雲端維持全空。
    } on CloudWipedException catch (e) {
      w.pullError = e;
    }
  });

  // ── Then ─────────────────────────────────────────────────
  runner.on(r'交易/帳戶/分類/附件全部清空$', (p) {
    for (final t in ['transactions', 'accounts', 'categories', 'attachments']) {
      expect(w._tableCount(t), 0, reason: '$t 應清空');
    }
  });

  runner.on(r'本地資料全部清空$', (p) {
    for (final t in ['transactions', 'accounts', 'categories', 'attachments']) {
      expect(w._tableCount(t), 0, reason: '$t 應清空');
    }
  });

  runner.on(r'附件檔案已刪除$', (p) {
    expect(w.blobsDir.existsSync(), isFalse, reason: 'blobs 目錄應已刪除');
  });

  runner.on(r'回到首次啟動狀態$', (p) {
    // 全表空（使用者表——sqlite_master 排除內部表；下次啟動播種將重跑）。
    final tables = w.db
        .select("SELECT name FROM sqlite_master WHERE type='table'"
            " AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%'")
        .map((r) => r['name'] as String)
        .toList();
    expect(tables, isNotEmpty);
    for (final t in tables) {
      expect(w._tableCount(t), 0, reason: '$t 應為空（首次啟動狀態）');
    }
  });

  runner.on(r'雲端 LedgerSync/ 整個資料夾已刪除（vault/devices/ops/backups 皆無）$', (p) async {
    expect(await w.cloud.list(''), isEmpty, reason: '雲端根應全空（vault/devices/ops/backups 皆無）');
  });

  runner.on(r'顯示「雲端資料已不存在」$', (p) {
    expect(w.pullError, isA<CloudWipedException>(), reason: 'pull 應偵測雲端已清空');
    expect(w.pullError.toString(), '雲端資料已不存在');
  });

  runner.on(r'裝置B 不會把舊資料同步回來$', (p) async {
    expect(await w.cloud.list(''), isEmpty,
        reason: 'pull 拋例外後 push 未執行——雲端維持全空（不復活）');
  });
}
