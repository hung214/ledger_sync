/// 平台分流「開庫」（P3 資料層 Web adapter；PM 2026-11-16 決策 A：採用 PWA）。
///
/// - **native**（Android／iOS／macOS／Windows）：FFI（`sqlite3_flutter_libs`）＋檔案路徑——行為與既有完全相同。
/// - **web**（PWA）：`sqlite3.wasm`（與 `sqlite3` 套件同版本）＋ **IndexedDB VFS** 持久化
///   （Spike SP-8 已於真實 Chrome 實測通過，techstack §6）。
///
/// 條件匯出：**`dart.library.io` 先判**——Dart 3.9 起 `dart.library.js_interop`
/// 於 VM／native 亦為 true（JS interop everywhere），不可作為首要判別。
/// `AppDatabase` 一律以 `CommonDatabase` 型別持有連線（native `Database` 亦實作之），
/// DAO／遷移程式碼**跨平台共用、零改動**。
library;

export 'db_opener_stub.dart'
    if (dart.library.io) 'db_opener_native.dart'
    if (dart.library.js_interop) 'db_opener_web.dart';
