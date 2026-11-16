/// 檔案輸出（P6 架構延續——條件匯出；分析期恆選 base，編譯期 CFE 分流）。
///
/// - native：`File.writeAsBytesSync`（同步——widget 測試可測；檔案小）
/// - web：`XFile.saveTo`（觸發瀏覽器下載；path 被忽略）
///
/// 詳見 `lib/data/sqlite/db_opener_stub.dart` 註解（stub 型別必須正確）。
library;

export 'file_saver_stub.dart'
    if (dart.library.io) 'file_saver_native.dart'
    if (dart.library.js_interop) 'file_saver_web.dart';
