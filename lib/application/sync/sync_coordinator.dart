import 'dart:convert';

import '../../core/hlc.dart';
import '../../data/sqlite/app_database.dart';
import '../../platform/cloud/cloud_storage_adapter.dart';
import '../scan/blob_store.dart';
import '../wipe/wipe_service.dart' show CloudWipedException;
import 'bundle_applier.dart';
import 'backup_service.dart';

/// 同步協調器（SDD §5.5.3 SyncCoordinator——檔案式 OpLog 合併）。
///
/// 佈局（§5.5.1）：vault.json（首次建置，僅寫一次）＋devices/{id}.json
/// （每裝置 manifest：last_seq/ack_seq）＋ops/{id}/{seq:08d}.opbundle
/// ＋blobs/{sha256}＋backups/{ts}.db。M5 無加密（.enc 僅 P2 選用，FR-Y7）。
///
/// 流程：pull（每 peer 下載 cursor+1..last_seq 依序套用）→ push（未打包
/// oplog → bundle(seq=last_seq+1) → 上傳＋manifest＋附件分流上傳）。
/// 冪等：同 seq 覆蓋同名內容＋套用端 cursor 跳過重複（§5.5.3）。
///
/// ⚠️ 同步合併模組：待雙重 review（research §1.3）。
class SyncCoordinator {
  SyncCoordinator(
    this._db,
    this._cloud, {
    required this.deviceId,
    this.blobs,
    this.onConflictEvent,
  });

  final AppDatabase _db;
  final CloudStorageAdapter _cloud;
  final String deviceId;

  /// 附件 blob 源（P5 起以 [BlobStore] 平台分流——native=檔案、web=IndexedDB；
  /// null＝跳過附件段）。
  final BlobStore? blobs;

  /// 衝突通知鉤子（N-8；測試 spy／正式通知）。
  final void Function(SyncEventRow event)? onConflictEvent;

  /// 網路型態（FR-Y11 附件分流：wifi | mobile；生產由 connectivity 判定，
  /// M5 為可變欄位 seam——情境切換）。
  String networkType = 'wifi';

  /// 重入閘（M5-FE：啟動鉤子×手動「立即同步」併發防護——進行中呼叫直接
  /// 跳過，避免循環觸發與 race；SDD §5.5.3 冪等語意下安全）。
  bool _syncRunning = false;

  static const _vaultPath = 'vault.json';
  static const _everSyncedKey = 'device.ever_synced';
  String _manifestPath(String id) => 'devices/$id.json';
  String _bundlePath(String id, int seq) =>
      'ops/$id/${seq.toString().padLeft(8, '0')}.opbundle';

  /// 同步回合（情境觸發點）：pull 套用 peers → push 未打包。
  /// 重入保護：進行中時後到呼叫直接跳過（返回即完成的已完成 Future）。
  ///
  /// 不復活閘（FR-O3；驗收 S9.2 #5——Critical 防線）：曾完成同步
  /// （device.ever_synced；settings 為本地表不入 oplog——per-device 語意）
  /// 而 vault.json 已不存在 → 雲端已被清空 → 拋 CloudWipedException：
  /// 不重建 vault、不 pull、**不 push 舊資料**。首次連結無旗標仍走
  /// _ensureVault 建置（新裝置/新帳本正常路徑）。
  Future<void> sync() async {
    if (_syncRunning) return;
    _syncRunning = true;
    try {
      if (await _cloud.download(_vaultPath) == null &&
          _db.getSetting(_everSyncedKey) == 'true') {
        throw const CloudWipedException('雲端資料已不存在');
      }
      await _ensureVault();
      await pull();
      // 武裝時機：pull 成功＝已確認 vault 在雲端（_ensureVault 上傳失敗會
      // 拋例外不到此——避免「建置未落雲」誤判雲端已清空）。
      _db.setSetting(_everSyncedKey, 'true');
      await push();
    } finally {
      _syncRunning = false;
    }
  }

  /// vault 首建（§5.5.1：僅首次寫入一次）。
  Future<void> _ensureVault() async {
    if (await readJson(_vaultPath) == null) {
      await writeJson(_vaultPath, {
        'schema_ver': _db.schemaVersion,
        'devices': [deviceId],
      });
    }
  }

  /// pull：各 peer manifest → cursor+1..last_seq bundle 依序套用。
  /// （list 回資料夾內相對檔名——manifest 讀取須拼回完整路徑。）
  /// vault 缺 → CloudWipedException（FR-O3「不復活」：其他裝置 pull 偵測
  /// 雲端已重置 → 停止同步，**不 push 舊資料**）。
  Future<void> pull() async {
    if (await _cloud.download(_vaultPath) == null) {
      throw const CloudWipedException('雲端資料已不存在');
    }
    final manifestFiles = await _cloud.list('devices');
    for (final file in manifestFiles) {
      final peer = file.replaceAll('.json', '');
      if (peer == deviceId) continue;
      final m = await readJson('devices/$file');
      final lastSeq = (m?['last_seq'] as int?) ?? 0;
      var cursor =
          int.tryParse(_db.getSetting('sync.cursor.$peer') ?? '') ?? 0;
      final applier = BundleApplier(_db, onConflictEvent: onConflictEvent);
      while (cursor < lastSeq) {
        cursor++;
        final bytes = await _cloud.download(_bundlePath(peer, cursor));
        if (bytes == null) break; // 缺檔保守停止（下次重試；cursor 未推進）
        final bundle = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
        final ops =
            (bundle['ops'] as List).cast<Map<String, Object?>>();
        applier.apply(peer, ops);
        _db.setSetting('sync.cursor.$peer', '$cursor');
      }
    }
  }

  /// push：未打包 oplog → bundle 上傳＋manifest＋vault 補錄＋附件分流。
  Future<void> push() async {
    var lastSeq = await lastSeqOf(deviceId);
    final ops = _db.unpackedOps();
    if (ops.isNotEmpty) {
      final seq = lastSeq + 1;
      await _cloud.upload(
        _bundlePath(deviceId, seq),
        utf8.encode(jsonEncode(buildBundle(deviceId, seq, ops))),
      );
      _db.markOpsPacked(seq);
      lastSeq = seq;
    }
    // manifest（每裝置只寫自己的——§5.5.3 跨裝置零衝突）。
    await writeJson(_manifestPath(deviceId), {
      'app_ver': 'dev',
      'schema_ver': _db.schemaVersion,
      'last_seq': lastSeq,
      'ack_seq': lastSeq,
    });
    // vault 補錄裝置（首次）。
    final vault = await readJson(_vaultPath);
    final devices = List<String>.from((vault?['devices'] as List?) ?? []);
    if (!devices.contains(deviceId)) {
      devices.add(deviceId);
      await writeJson(_vaultPath, {
        'schema_ver': _db.schemaVersion,
        'devices': devices,
      });
    }
    await _pushBlobs();
  }

  /// 附件 blob 上傳（§5.5.6 內容定址去重＋FR-Y11 Wi-Fi 分流）。
  Future<void> _pushBlobs() async {
    final store = blobs;
    if (store == null) return;
    final wifiOnly =
        _db.getSetting('backup.attachments_wifi_only') == 'true';
    if (wifiOnly && networkType != 'wifi') return; // 行動網路暫緩
    for (final a in _db.allAttachments()) {
      final path = 'blobs/${a.sha256}';
      if (await _cloud.download(path) != null) continue; // 內容定址去重
      final bytes = await store.read(a.sha256);
      if (bytes != null) {
        await _cloud.upload(path, bytes);
      }
    }
  }

  /// 新裝置 bootstrap（FR-Y2/AC-08）：最新備份匯入→全量 replay（冪等）
  /// →清 cursor（還原之 settings 不帶前裝置游標）→寫 manifest（last_seq=0）。
  Future<void> bootstrap() async {
    await _ensureVault();
    final backups = await _cloud.list('backups')..sort();
    if (backups.isNotEmpty) {
      final backup = BackupService(_db, _cloud, deviceId: deviceId);
      await backup.importInto(_db, 'backups/${backups.last}');
      for (final key in [
        for (final s in _db.select("SELECT key FROM settings WHERE key LIKE 'sync.cursor.%'"))
          s['key'] as String,
      ]) {
        _db.execute('DELETE FROM settings WHERE key = ?', [key]);
      }
    }
    await pull(); // 自備份時間點後之 bundles（M5 全量 replay 冪等）
    // 武裝不復活閘（FR-O3）：bootstrap 已觀察到 vault——之後雲端被清空時，
    // 本裝置下次 sync() 須偵測而非重建 vault 推回舊資料。
    _db.setSetting(_everSyncedKey, 'true');
    await writeJson(_manifestPath(deviceId), {
      'app_ver': 'dev',
      'schema_ver': _db.schemaVersion,
      'last_seq': 0, // 尚未 push（AC-08）
      'ack_seq': 0,
    });
    final vault = await readJson(_vaultPath);
    final devices = List<String>.from((vault?['devices'] as List?) ?? []);
    if (!devices.contains(deviceId)) {
      devices.add(deviceId);
      await writeJson(_vaultPath, {
        'schema_ver': _db.schemaVersion,
        'devices': devices,
      });
    }
  }

  // ── 雲端檔案 JSON 輔助（harness/模組共用） ────────────────

  Future<Map<String, Object?>?> readJson(String path) async {
    final bytes = await _cloud.download(path);
    if (bytes == null) return null;
    return jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
  }

  Future<void> writeJson(String path, Map<String, Object?> json) =>
      _cloud.upload(path, utf8.encode(jsonEncode(json)));

  /// 裝置 manifest 之 last_seq（無 manifest→0）。
  Future<int> lastSeqOf(String id) async {
    final m = await readJson(_manifestPath(id));
    return (m?['last_seq'] as int?) ?? 0;
  }
}

/// bundle 上傳之 ops 載荷組裝（未打包 oplog → OpBundle JSON，SDD §5.5.2）。
Map<String, Object?> buildBundle(
        String deviceId, int seq, List<OplogRow> ops) =>
    {
      'device_id': deviceId,
      'seq': seq,
      'schema_ver': 4,
      'ops': [
        for (final o in ops)
          {
            'e': o.entity,
            'id': o.entityId,
            'hlc': o.hlc,
            'row':
                o.payload == null ? null : jsonDecode(o.payload!) as Map<String, Object?>,
          },
      ],
    };

/// 新 oplog 列（整列快照 payload；packed_seq=null 待打包）。
OplogRow opFor(String entity, String entityId, String hlc, Map<String, Object?> snapshot) =>
    OplogRow(
      entity: entity,
      entityId: entityId,
      hlc: hlc,
      payload: jsonEncode(snapshot),
      packedSeq: null,
    );

/// 新 HLC 版本戳（Clock 單一來源；deviceId 注入）。
String newHlc(String deviceId) => Hlc.now(deviceId).toString();
