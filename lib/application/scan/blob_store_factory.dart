/// BlobStore 平台分流工廠（P4；條件匯出）。
///
/// - **native**（Android／iOS／macOS／Windows）：檔案系統 `blobs/{sha256}`
///   （行為與 v0.4.x 完全一致）。
/// - **web**（PWA）：IndexedDB key-value（key=sha256）。
///
/// ⚠ 分析期（dart analyze/flutter analyze）**恆選 base（stub）**——stub 型別必須
/// 正確（勿 `Never`）；真正編譯時 CFE 才依目標平台分流。
/// 詳見 `lib/data/sqlite/db_opener_stub.dart` 與 `tasks.md` §6.0b P3.3。
library;

export 'blob_store_stub.dart'
    if (dart.library.io) 'blob_store_native.dart'
    if (dart.library.js_interop) 'blob_store_web.dart';
