/// 桌面每日自動本地備份（facade；條件匯出）。
///
/// - native：>24h 自動寫 `<documents>/ledger_sync/backups/ledger_auto_*.db`
///   （明文快照，與「備份到檔案」同格式——可用「從檔案還原」救回）＋保留 7 份 GC。
/// - web：無本地檔案系統 → 不做（雲端備份取代）。
///
/// 設定鍵：`backup.local.last_at`。分析期恁選 base（型別正確；見 db_opener_stub 註解）。
library;

export 'local_backup_stub.dart'
    if (dart.library.io) 'local_backup_io.dart'
    if (dart.library.js_interop) 'local_backup_web.dart';
