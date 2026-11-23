/// 掃描頁重載後自動導航旗標（T65；平台分流——**只能由條件匯出提供**，
/// 本檔不得宣告同名本地函式：Dart 本地宣告會遮蔽條件匯出造成死碼，
/// DBG-018 同族教訓）。
///
/// web：讀取並清除 sessionStorage `ls_pending_scan`（相機整頁重載後
/// AppRoot 接手導回掃描頁）；其他平台：恆 null（無此機制）。
library;

export 'pending_scan_nav_stub.dart'
    if (dart.library.js_interop) 'pending_scan_nav_web.dart';
