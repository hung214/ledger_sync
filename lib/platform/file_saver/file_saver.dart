/// 平台分流「CSV 匯出存檔」（PM 2026-11-19 修復：匯出只 print 未存檔）。
///
/// - **native**（Android／iOS／macOS／Windows）：`file_selector` 存檔對話框
///   → 使用者選路徑 → 寫入位元組（UTF-8＋BOM 由呼叫端備妥）。
/// - **web**（PWA）：`Blob`＋`<a download>` 點擊 → 瀏覽器下載。
///
/// 條件匯出：**`dart.library.io` 先判**——Dart 3.9 起 `dart.library.js_interop`
/// 於 VM／native 亦為 true，不可作為首要判別。
/// 分析期恆選 base 檔（`file_saver_stub.dart`）——**型別必須正確（勿 Never）**。
library;

export 'file_saver_stub.dart'
    if (dart.library.io) 'file_saver_io.dart'
    if (dart.library.js_interop) 'file_saver_web.dart';
