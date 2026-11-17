import '../../data/sqlite/app_database.dart';

/// web（PWA）：無本地檔案系統——自動本地備份不適用（雲端備份取代）。
Future<String?> runLocalBackupIfNeeded(
  AppDatabase db,
  String dirPath, {
  int keep = 7,
  int? nowMs,
}) async =>
    null;
