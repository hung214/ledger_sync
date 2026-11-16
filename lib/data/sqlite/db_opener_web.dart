import 'package:sqlite3/wasm.dart';

/// Web（PWA）開庫：`sqlite3.wasm`＋**IndexedDB VFS**（持久化）。
///
/// - wasm 檔：`web/sqlite3.wasm`（與 `sqlite3` 套件**同版本** 2.9.4；版本錯位會 ABI 不相容）。
/// - wasm 以**相對頁面根** URL 載入（`flutter build web` 會把 `web/` 原樣部署至站點根）。
/// - `flutter test --platform chrome` 的測試伺服器**不提供** assets/web → 測試請走
///   headless Chrome 對 `build/web` 實測（Spike SP-8 模式，見 tasks §6.0b）。
const String kSqliteWasmUrl = 'sqlite3.wasm';
const String kWebDbFileName = 'ledger.db';
const String kWebIndexedDbName = 'ledger_sync_db';

WasmSqlite3? _sqlite3;
IndexedDbFileSystem? _vfs;
bool _vfsRegistered = false;

/// 載入（單例快取）wasm 版 sqlite3。
Future<WasmSqlite3> loadWebSqlite() async {
  final cached = _sqlite3;
  if (cached != null) return cached;
  final loaded = await WasmSqlite3.loadFromUrl(Uri.parse(kSqliteWasmUrl));
  _sqlite3 = loaded;
  return loaded;
}

/// 開啟**持久化** App DB（IndexedDB VFS；跨重新載入存活）。
/// 回傳型別為 `CommonDatabase`——與 native 同介面，DAO 零改動。
Future<CommonDatabase> openAppDatabaseWeb() async {
  final sqlite = await loadWebSqlite();
  if (!_vfsRegistered) {
    _vfs = await IndexedDbFileSystem.open(dbName: kWebIndexedDbName);
    sqlite.registerVirtualFileSystem(_vfs!, makeDefault: true);
    _vfsRegistered = true;
  }
  return sqlite.open(kWebDbFileName);
}

/// native 專用開庫於 Web 不存在（請用 [openAppDatabaseWeb]）。
Never openNative({String? path}) =>
    throw UnsupportedError('openNative() 僅供原生平台（path：$path；Web 請用 openAppDatabaseWeb()）');

/// 沖刷並關閉 VFS（IndexedDB 落盤；Spike／驗證流程結束時呼叫）。
Future<void> closeWebVfs() async {
  await _vfs?.flush();
  await _vfs?.close();
  _vfs = null;
  _vfsRegistered = false;
}

void ensureSqliteOpenable() {}
