import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';

import '../../core/clock.dart';
import '../../core/hlc.dart';
import '../../data/sqlite/app_database.dart';
import 'blob_store.dart';

/// 附件儲存服務（SDD §5.4 附件儲存——FR-S4）：
/// 原圖縮至最長邊 1600px → JPEG q70 → sha256 → 存 `blobs/{sha256}` →
/// 寫入 attachments 列（與 oplog 同一 DB transaction——attachments 屬
/// sync_entity，SDD §5.1 契約）。
///
/// 純 Dart `image` 套件壓縮：**跨平台位元組一致** → 同張照片各裝置壓縮後
/// sha256 相同 → 雲端 blobs/ 內容定址去重成立（SDD §5.5.6；techstack v0.3.7）。
///
/// **平台中立**（P4 附件層 Web adapter；PM 2026-11-16 決策 A）：落盤經
/// [BlobStore] 抽象（native=檔案系統；web=IndexedDB），DB 邏輯零改動。
/// `save()` 於 P4 起為 **async**（web 無同步檔案 I/O）。
class AttachmentStore {
  /// [_blobs]＝平台分流之 BlobStore（native=檔案系統；web=IndexedDB）。
  AttachmentStore(this._db, this._blobs, {this.deviceId = 'device-local'});

  final AppDatabase _db;

  /// Blob 儲存（平台分流；測試注入暫存目錄之 FileBlobStore）。
  final BlobStore _blobs;

  /// HLC 裝置 id（M4 本地單機；F07 多裝置時由裝置註冊提供）。
  final String deviceId;

  /// 壓縮最長邊上限（SDD §5.4）。
  static const int maxLongestEdge = 1600;

  /// JPEG 品質（SDD §5.4）。
  static const int jpegQuality = 70;

  /// 讀取附件內容（呈現／同步用；不存在回 null）。
  Future<Uint8List?> read(String sha256) => _blobs.read(sha256);

  /// 儲存附件：壓縮→定址→落盤→DB 列（含 oplog，同一 DB transaction）。回傳落地資訊。
  Future<StoredAttachment> save({
    required List<int> imageBytes,
    required String transactionId,
    String? mime,
  }) async {
    final jpeg = compress(imageBytes);
    final digest = sha256.convert(jpeg).toString();

    // 落盤（冪等：內容定址——同名必同內容，重複儲存為覆寫 no-op）。
    await _blobs.write(digest, jpeg);

    // attachments 列＋oplog（attachments 屬 sync_entity；SDD §5.1 儲存事務）。
    final nowMs = Clock.now().millisecondsSinceEpoch;
    final hlc = Hlc.now(deviceId).toString();
    final row = AttachmentRow(
      id: const Uuid().v7(),
      transactionId: transactionId,
      sha256: digest,
      mime: mime ?? 'image/jpeg',
      byteSize: jpeg.length,
      createdAt: nowMs,
      hlc: hlc,
    );
    _db.insertAttachmentWithOplog(
      row,
      OplogRow(
        entity: 'attachments',
        entityId: row.id,
        hlc: hlc,
        payload: jsonEncode(row.toSnapshot()),
        packedSeq: null,
      ),
    );

    return StoredAttachment(
      sha256: digest,
      byteSize: jpeg.length,
      longestEdge: _longestEdgeOf(jpeg),
      row: row,
    );
  }

  /// 壓縮核心（pure：bytes→bytes）。原圖最長邊 ≤1600 時不放大、僅重編 JPEG。
  static Uint8List compress(List<int> imageBytes) {
    final image = img.decodeImage(Uint8List.fromList(imageBytes));
    if (image == null) {
      throw const FormatException('附件壓縮失敗：無法解碼圖片');
    }
    final longest = image.width >= image.height ? image.width : image.height;
    var resized = image;
    if (longest > maxLongestEdge) {
      final scale = maxLongestEdge / longest;
      resized = img.copyResize(
        image,
        width: (image.width * scale).round(),
        height: (image.height * scale).round(),
      );
    }
    return img.encodeJpg(resized, quality: jpegQuality);
  }

  static int _longestEdgeOf(Uint8List jpeg) {
    final decoded = img.decodeImage(jpeg);
    if (decoded == null) return 0;
    return decoded.width >= decoded.height ? decoded.width : decoded.height;
  }
}

/// 附件落地結果（S5 斷言：檔名=blobs/{sha256}、尺寸、關聯）。
class StoredAttachment {
  const StoredAttachment({
    required this.sha256,
    required this.byteSize,
    required this.longestEdge,
    required this.row,
  });

  /// 壓縮後內容之 sha256（檔名與 attachments.sha256 同源）。
  final String sha256;
  final int byteSize;
  final int longestEdge;
  final AttachmentRow row;
}
