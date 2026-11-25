/// Web（PWA）檔案選取器：用 `<input type="file">` 取代 `file_selector` 的
/// `openFile()`——後者依賴 File System Access API（`showOpenFilePicker`），
/// **iOS Safari 僅支援 image/video**，無法挑選 .db/.csv 等任意檔案
/// （PM 2026-11-23 實測：iPhone PWA「從檔案還原」找不到檔案）。
///
/// `<input type="file">` 為全瀏覽器相容（含 iOS Safari／PWA standalone），
/// 點按後跳出 iOS 原生「檔案」App 選單（iCloud Drive／本機／第三方雲端）。
///
/// 用法：
///   final file = await pickWebFile(accept: '.db,.json');
///   final bytes = await file.readAsBytes();
///
/// 條件匯出（stub 型別必須正確——詳見 `lib/data/sqlite/db_opener_stub.dart`）。
library;

export 'web_file_picker_stub.dart'
    if (dart.library.js_interop) 'web_file_picker_web.dart';
