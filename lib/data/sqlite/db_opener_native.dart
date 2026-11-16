import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/common.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// Windows 測試環境：系統內建 winsqlite3.dll（App 執行時由 sqlite3_flutter_libs
/// 提供 bundled sqlite3）。須在任何開庫動作前呼叫一次。
void ensureSqliteOpenable() {
  if (Platform.isWindows) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
}

/// native 開庫（行為與 v0.4.x 完全一致）。
/// [path] 為 null → in-memory（測試用）。
CommonDatabase openNative({String? path}) {
  ensureSqliteOpenable();
  return path == null
      ? sqlite3.openInMemory()
      : sqlite3.open(path, mode: OpenMode.readWriteCreate);
}

/// Web 專用開庫於 native 平台不存在（請用 [openNative]）。
Future<CommonDatabase> openAppDatabaseWeb() async =>
    throw UnsupportedError('openAppDatabaseWeb() 僅供 Web 平台（native 請用 openNative()）');

/// Web VFS 於 native 不存在（no-op；與 db_opener_web 同名介面）。
Future<void> closeWebVfs() async {}
