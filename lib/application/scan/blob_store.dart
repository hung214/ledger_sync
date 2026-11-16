import 'dart:typed_data';

/// 附件 Blob 儲存**介面**（P4 附件層 Web adapter；PM 2026-11-16 決策 A）。
///
/// 內容定址語意跨平台不變（SDD §5.4/§5.5.6）：
/// - key＝壓縮後內容之 sha256（`blobs/{sha256}` 於 native；IndexedDB key 於 web）。
/// - `write` 冪等：同名必同內容，重複儲存為覆寫 no-op。
///
/// 平台分流工廠見 `blob_store_factory.dart`（條件匯出；分析期恆選 stub——
/// 型別必須正確，教訓見 `lib/data/sqlite/db_opener_stub.dart` 註解）。
abstract interface class BlobStore {
  /// 寫入（冪等覆寫）。
  Future<void> write(String sha256, Uint8List bytes);

  /// 讀取；不存在回 null。
  Future<Uint8List?> read(String sha256);

  /// 刪除（不存在為 no-op）。
  Future<void> delete(String sha256);
}
