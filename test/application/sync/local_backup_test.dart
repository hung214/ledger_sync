import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/sync/local_backup.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';

/// 桌面每日自動本地備份（I5+/安全網）：
/// >24h 閘、檔案產生（可還原格式）、保留 7 份 GC、手動備份檔不受影響。
void main() {
  late AppDatabase db;
  late Directory tmp;
  final now = DateTime(2026, 11, 17, 10, 0).millisecondsSinceEpoch;

  setUp(() {
    db = AppDatabase.inMemory();
    tmp = Directory.systemTemp.createTempSync('ledger_autobk');
    // 造一筆交易（備份內容應含）
    db.select(
        "INSERT INTO accounts (id,type,name,currency,opening_amount_minor,"
        "archived,created_at,updated_at,hlc) VALUES ('a-1','cash','現金','TWD',0,0,1,1,'0.t')");
    db.select(
        "INSERT INTO transactions (id,kind,amount_minor,currency,account_id,"
        "occurred_at,source,settlement_status,created_at,updated_at,hlc) "
        "VALUES ('t-1','expense',5000,'TWD','a-1',1760000000000,'manual','none',1,1,'0.t')");
  });
  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  test('首次執行：產生備份檔＋寫入時間戳', () async {
    final path = await runLocalBackupIfNeeded(db, tmp.path, nowMs: now);
    expect(path, isNotNull);
    expect(File(path!).existsSync(), isTrue);
    final content = File(path).readAsStringSync();
    expect(content, contains('transactions'), reason: '明文快照（flag=0 後為 JSON）');
    expect(db.getSetting('backup.local.last_at'), '$now');
  });

  test('24h 內重複執行：不重複備份（回 null）', () async {
    await runLocalBackupIfNeeded(db, tmp.path, nowMs: now);
    final again =
        await runLocalBackupIfNeeded(db, tmp.path, nowMs: now + 3600000);
    expect(again, isNull);
  });

  test('超過 24h：再次備份', () async {
    await runLocalBackupIfNeeded(db, tmp.path, nowMs: now);
    final next =
        await runLocalBackupIfNeeded(db, tmp.path, nowMs: now + 25 * 3600000);
    expect(next, isNotNull);
  });

  test('GC：自動備份保留 7 份；手動備份（ledger_backup_）不受影響', () async {
    for (var i = 0; i < 9; i++) {
      await runLocalBackupIfNeeded(
          db, tmp.path, nowMs: now + i * 25 * 3600000);
    }
    final autos = tmp
        .listSync()
        .whereType<File>()
        .where((f) => f.path.split('/').last.startsWith('ledger_auto_'))
        .toList();
    expect(autos.length, 7, reason: 'GC 保留 7 份');
    File('${tmp.path}/ledger_backup_manual.db').writeAsStringSync('x');
    await runLocalBackupIfNeeded(db, tmp.path, nowMs: now + 10 * 25 * 3600000);
    expect(File('${tmp.path}/ledger_backup_manual.db').existsSync(), isTrue,
        reason: '手動備份不應被 GC');
  });
}
