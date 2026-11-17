import '../../data/sqlite/app_database.dart';

/// base 樁（分析期恆選本檔；型別必須與兩平台實作一致——勿 Never）。
Future<String?> runLocalBackupIfNeeded(
  AppDatabase db,
  String dirPath, {
  int keep = 7,
  int? nowMs,
}) async =>
    null;
