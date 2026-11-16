
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/transaction_draft.dart';
import '../providers.dart';
import 'attachment_store.dart';
import 'blob_store.dart';

/// 掃描管線狀態（F03-FE；SDD §5.4 ReceiptPipeline 呈現面）。
///
/// 注入約定（同 dbProvider）：測試以 fake 回放 override/直呼 notifier
/// （dsl「影像回放注入掃描器」——QR/OCR 引擎為平台層，FE 情境以解析結果
/// 注入驗 UI 流程；行動相機接線 mobile_scanner 屬 acceptance 走查前補）。

/// 掃描結果暫存（連拍：每掃一張 add 一筆；「完成掃描」進確認清單）。
final scanDraftsProvider =
    NotifierProvider<ScanDraftsNotifier, List<ScannedItem>>(
        ScanDraftsNotifier.new);

class ScannedItem {
  const ScannedItem({required this.draft, this.photoBytes});

  /// 解析草稿（QR：InvoiceQrParser；OCR：ReceiptFieldExtractor；回退：blank）。
  final TransactionDraft draft;

  /// 掃描影像（附件來源；null＝無原圖——手動輸入）。
  final Uint8List? photoBytes;
}

class ScanDraftsNotifier extends Notifier<List<ScannedItem>> {
  @override
  List<ScannedItem> build() => const [];

  /// 掃到一張（影像回放注入點＝掃描器回呼契約）。
  void add(ScannedItem item) => state = [...state, item];

  /// 開新掃描回合（進掃描頁時清空）。
  void reset() => state = const [];
}

/// 相機權限（FR-S6；M4 in-app stub——平台 permission_handler 接線屬
/// mobile_scanner 整合時補，狀態機契約不變）。
enum CameraPermissionState { notDetermined, granted, denied }

final cameraPermissionProvider =
    NotifierProvider<CameraPermissionNotifier, CameraPermissionState>(
        CameraPermissionNotifier.new);

class CameraPermissionNotifier extends Notifier<CameraPermissionState> {
  @override
  CameraPermissionState build() => CameraPermissionState.notDetermined;

  void allow() => state = CameraPermissionState.granted;
  void deny() => state = CameraPermissionState.denied;
}

/// 相機可用性（FR-S6：無相機裝置 → 掃描導向相簿/檔案匯入）。
/// M4：桌面（macOS/Windows）無相機整合＝false；行動＝true。
/// P8（Web/PWA）：**恆 false**——web 不走行動相機外掛路徑（mobile_scanner；
/// SP-2b），一律檔案匯入（file_selector web ✓）。
final cameraAvailableProvider =
    NotifierProvider<CameraAvailableNotifier, bool>(CameraAvailableNotifier.new);

class CameraAvailableNotifier extends Notifier<bool> {
  @override
  bool build() =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  void set(bool available) => state = available;
}

/// 附件索引（交易 id 集合；明細 📷 標記用——儲存附件後 refresh）。
final attachmentTxIdsProvider =
    NotifierProvider<AttachmentTxIdsNotifier, Set<String>>(
        AttachmentTxIdsNotifier.new);

class AttachmentTxIdsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => _collect();

  Set<String> _collect() {
    final db = ref.watch(dbProvider);
    return {
      for (final row in db.allAttachments())
        if (row.deletedAt == null) row.transactionId,
    };
  }

  /// 附件落地後刷新（ReviewPage 儲存呼叫）。
  void refresh() => state = _collect();
}

/// 附件 Blob 儲存（P4 平台分流）：native＝main() 以
/// `newBlobStore(dirPath: blobs 目錄)` override；web＝`newBlobStore()`（IndexedDB）。
final blobStoreProvider = Provider<BlobStore>((ref) {
  throw UnimplementedError('blobStoreProvider 須於 main() 或測試 override 注入');
});

/// 附件儲存服務（FR-S4；BE S5 已驗壓縮/定址契約——FE 為接線）。
final attachmentStoreProvider = Provider(
    (ref) => AttachmentStore(ref.watch(dbProvider), ref.watch(blobStoreProvider)));

/// 相簿/檔案匯入管線 seam（FR-S6 桌面路徑）：生產＝檔案選擇器＋OCR 引擎
/// （平台層）；測試 override 回放 T-H6 fixture。回 null＝使用者取消。
final importPipelineProvider = Provider<Future<ScannedItem?> Function()>((ref) {
  throw UnimplementedError('importPipelineProvider 須於生產/測試 override 注入');
});
