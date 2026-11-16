import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/clock.dart';
import '../../data/sqlite/app_database.dart';
import '../../platform/cloud/cloud_storage_adapter.dart';

/// 備份服務（SDD §5.5.1 backups/；FR-Y3 GC＋FR-Y6/AC-14 檔案密碼）。
///
/// 快照格式（M5）：JSON（各表全列）→（密碼→AES-256-GCM，D8）→
/// `backups/{yyyyMMdd_HHmmss}.db`。每日自動（>24h）＋保留份數 GC
/// （settings backup.keep，預設 7）。
///
/// 密碼金鑰：sha256(password)（32B）——TODO(SP-4)：換 Argon2id（truth D8：
/// 備份檔密碼 KDF；research TR-4 效能）。
class BackupService {
  BackupService(this._db, this._cloud, {required this.deviceId});

  final AppDatabase _db;
  final CloudStorageAdapter _cloud;

  /// manifest 所屬裝置（快照 metadata；檔名時間戳唯一已免衝突）。
  final String deviceId;

  final AesGcm _aesGcm = AesGcm.with256bits(); // 非 const（工廠）

  String _backupPath(DateTime t) =>
      'backups/${t.year.toString().padLeft(4, '0')}'
      '${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}'
      '_${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}'
      '${t.second.toString().padLeft(2, '0')}.db';

  /// 每日自動備份（>24h）＋GC 超額舊份（FR-Y3）。回傳本次是否產生備份。
  Future<bool> runIfNeeded() async {
    final last = int.tryParse(_db.getSetting('backup.last_at') ?? '') ?? 0;
    final now = Clock.now();
    if (now.millisecondsSinceEpoch - last <
        const Duration(hours: 24).inMilliseconds) {
      return false;
    }
    await export();
    _db.setSetting('backup.last_at', '${now.millisecondsSinceEpoch}');
    return true;
  }

  /// 匯出備份（[password] null＝不加密，預設；FR-Y6 Outline 選項）。
  /// 回傳雲端路徑。
  Future<String> export({String? password}) async {
    final bytes = await encode(snapshot(), password: password);
    final path = _backupPath(Clock.now());
    await _cloud.upload(path, Uint8List.fromList(bytes));
    await _gc();
    return path;
  }

  /// 保留份數 GC（FR-Y3：超額刪最舊；keep 讀 settings backup.keep，預設 7）。
  Future<void> _gc() async {
    final keep = int.tryParse(_db.getSetting('backup.keep') ?? '') ?? 7;
    final files = await _cloud.list('backups')..sort();
    while (files.length > keep) {
      await _cloud.delete('backups/${files.first}');
      files.removeAt(0);
    }
  }

  /// 匯入備份至 [target]（另一環境/新裝置；錯誤密碼拋例外且 target 不變——
  /// 解密發生於清空之前，AC-14）。
  Future<void> importInto(
    AppDatabase target,
    String cloudPath, {
    String? password,
  }) async {
    final bytes = await _cloud.download(cloudPath);
    if (bytes == null) throw StateError('備份不存在：$cloudPath');
    await restoreFromBytes(target, bytes, password: password);
  }

  /// 從**備份檔內容**還原（I5+/本機備份：資料管理「從檔案還原」；
  /// 與雲端 importInto 同一落地路徑——冪等全量覆蓋＋單一 DB transaction）。
  Future<void> restoreFromBytes(
    AppDatabase target,
    Uint8List bytes, {
    String? password,
  }) async {
    final snap = await decode(bytes, password: password);
    final tables = [
      'statement_items', 'refund_links', 'statement_items', 'attachments',
      'installment_plans', 'statements', 'credit_card_details',
      'income_goals', 'budgets', 'transactions', 'templates', 'categories',
      'accounts', 'settings', 'oplog',
    ];
    target.runInTransaction(() {
      for (final t in tables.toSet()) {
        target.clearTable(t);
      }
      for (final entry in snap.entries) {
        if (entry.key == 'schema_ver' || entry.key == 'created_at') continue;
        for (final row in (entry.value as List).cast<Map<String, Object?>>()) {
          target.restoreRow(entry.key, row);
        }
      }
    });
  }

  /// 全表快照（匯出用；逐表 SELECT——SDD §5.5.1 全量快照）。
  Map<String, Object?> snapshot() {
    final tables = [
      'accounts', 'categories', 'transactions', 'oplog', 'settings', 'templates',
      'budgets', 'income_goals', 'credit_card_details', 'statements',
      'statement_items', 'refund_links', 'installment_plans', 'attachments',
    ];
    return {
      'schema_ver': _db.schemaVersion,
      'created_at': Clock.now().millisecondsSinceEpoch,
      for (final t in tables) t: _db.select('SELECT * FROM $t'),
    };
  }

  /// 快照 JSON bytes（密碼非 null 時 AES-256-GCM：
  /// `LSBK1:P|N + nonce + mac + cipher` 自訂框）。
  Future<List<int>> encode(Map<String, Object?> snapshot,
      {String? password}) async {
    final plain = utf8.encode(jsonEncode(snapshot));
    if (password == null) return [0, ...plain]; // [flag=0 明文]
    final key = _keyFrom(password);
    final nonce = _aesGcm.newNonce();
    final box = await _aesGcm.encrypt(
      Uint8List.fromList(plain),
      secretKey: SecretKey(Uint8List.fromList(key)),
      nonce: nonce,
    );
    return [
      1, // flag=1 加密
      ...nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ];
  }

  /// 快照解碼（錯誤密碼 → MAC 驗證失敗拋例外——AC-14 拒絕匯入）。
  Future<Map<String, Object?>> decode(List<int> bytes, {String? password}) async {
    final flag = bytes.first;
    final body = bytes.sublist(1);
    if (flag == 0) {
      return jsonDecode(utf8.decode(body)) as Map<String, Object?>;
    }
    final nonce = body.sublist(0, 12);
    final mac = Mac(body.sublist(12, 28));
    final cipher = body.sublist(28);
    final key = _keyFrom(password ?? '');
    final plain = await _aesGcm.decrypt(
      SecretBox(Uint8List.fromList(cipher), nonce: nonce, mac: mac),
      secretKey: SecretKey(Uint8List.fromList(key)),
    ); // 錯誤密碼 → SecretBoxAuthenticationError
    return jsonDecode(utf8.decode(plain)) as Map<String, Object?>;
  }

  List<int> _keyFrom(String password) {
    // TODO(SP-4)：Argon2id（truth D8；M5 最小實作——密碼位元組循環填 32B）。
    if (password.isEmpty) return List<int>.filled(32, 0);
    return List<int>.generate(
        32, (i) => password.codeUnits[i % password.codeUnits.length] & 0xFF);
  }
}
