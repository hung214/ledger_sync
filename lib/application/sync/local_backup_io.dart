import 'dart:io';
import 'dart:typed_data';

import '../../data/sqlite/app_database.dart';
import '../../platform/cloud/unconfigured_cloud_adapter.dart';
import 'backup_service.dart';

/// 每日自動本地備份（>24h；保留 [keep] 份 GC）。
/// 回傳本次備份檔路徑；未到時間回 null。
Future<String?> runLocalBackupIfNeeded(
  AppDatabase db,
  String dirPath, {
  int keep = 7,
  int? nowMs,
}) async {
  final last = int.tryParse(db.getSetting('backup.local.last_at') ?? '') ?? 0;
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  if (now - last < const Duration(hours: 24).inMilliseconds) return null;

  final svc =
      BackupService(db, const UnconfiguredCloudAdapter(), deviceId: 'local-backup');
  final bytes = Uint8List.fromList(await svc.encode(svc.snapshot()));

  final dir = Directory(dirPath);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final t = DateTime.fromMillisecondsSinceEpoch(now);
  final name = 'ledger_auto_'
      '${t.year.toString().padLeft(4, '0')}'
      '${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}'
      '_${t.hour.toString().padLeft(2, '0')}'
      '${t.minute.toString().padLeft(2, '0')}.db';
  final path = '${dir.path}/$name';
  File(path).writeAsBytesSync(bytes, flush: true);
  db.setSetting('backup.local.last_at', '$now');

  // GC：僅清 ledger_auto_*.db（手動備份 ledger_backup_* 不受影響），保留最近 [keep] 份。
  final autos = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.split('/').last.startsWith('ledger_auto_'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  while (autos.length > keep) {
    autos.first.deleteSync();
    autos.removeAt(0);
  }
  return path;
}
