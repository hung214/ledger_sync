import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

import '../../application/scan/scan_state.dart';
import '../../domain/entities/transaction_draft.dart';
import '../../domain/services/invoice_qr_parser.dart';

/// **PC／桌面掃描（無相機）＝從圖片檔匯入**（PM 2026-10-29 決策）。
///
/// 流程：檔案對話框選圖 → 影像內解 QR（純 Dart `zxing2`＋既有 `image`；**無原生相依**）
/// → `InvoiceQrParser` 組草稿 → `ReviewPage` 逐張確認。
///
/// - 台灣電子發票左右各一 QR：先在**整張**找，找不到再切成**左右半／上下半／四象限**
///   逐區嘗試（實務上左右碼位於同一列，切半即可分別解出）。
/// - 找不到可辨識的 QR → 回退 `TransactionDraft.blank`（FR-S2／S3.6：空白確認卡＋
///   「無法辨識此發票格式」提示），使用者可手動補。
/// - 使用者取消選檔 → 回 null（不建立任何草稿）。
class ImageQrScanner {
  const ImageQrScanner();

  /// 生產用管線（注入 `importPipelineProvider`）。
  Future<ScannedItem?> pickAndScan() async {
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(
        label: '發票／收據圖片',
        extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
      ),
    ]);
    if (file == null) return null; // 使用者取消
    final bytes = await file.readAsBytes();
    return itemFromImage(bytes);
  }

  /// 由影像位元組建立掃描項（可單獨測試；不經檔案對話框）。
  ScannedItem itemFromImage(Uint8List bytes, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final draft = draftFromImage(bytes, now: at) ??
        TransactionDraft.blank(at); // 無法辨識 → 空白確認卡（FR-S2）
    return ScannedItem(draft: draft, photoBytes: bytes);
  }

  /// 解 QR → 草稿；無可辨識發票回 null。
  TransactionDraft? draftFromImage(Uint8List bytes, {DateTime? now}) =>
      draftFromQrTexts(decodeQrTexts(bytes));

  /// 由 QR 文字組出發票草稿（左碼 77 碼＋右碼明細；僅左碼亦可——S3.2 舊式單碼）。
  static TransactionDraft? draftFromQrTexts(List<String> texts) {
    String? left;
    String? right;
    for (final t in texts) {
      if (t.length == 77) {
        left ??= t;
      } else {
        right ??= t;
      }
    }
    if (left == null) return null;
    return right == null
        ? InvoiceQrParser.parseLeft(left)
        : InvoiceQrParser.parse(left, right);
  }

  /// 解出影像中所有 QR 文字（去重、最多 [_maxCodes] 個）。
  static List<String> decodeQrTexts(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return const [];
    final found = <String>[];
    for (final region in _regions(decoded)) {
      final text = _decodeRegion(region);
      if (text != null && !found.contains(text)) found.add(text);
      if (found.length >= _maxCodes) break;
    }
    return found;
  }

  static const int _maxCodes = 4;

  /// 嘗試區域：整張 → 左／右半 → 上／下半 → 四象限（發票雙 QR 多在左右）。
  static Iterable<img.Image> _regions(img.Image src) sync* {
    final w = src.width;
    final h = src.height;
    img.Image crop(int x, int y, int cw, int ch) =>
        img.copyCrop(src, x: x, y: y, width: cw, height: ch);

    yield src;
    if (w >= 40) {
      yield crop(0, 0, w ~/ 2, h);
      yield crop(w ~/ 2, 0, w - w ~/ 2, h);
    }
    if (h >= 40) {
      yield crop(0, 0, w, h ~/ 2);
      yield crop(0, h ~/ 2, w, h - h ~/ 2);
    }
    if (w >= 40 && h >= 40) {
      yield* [
        crop(0, 0, w ~/ 2, h ~/ 2),
        crop(w ~/ 2, 0, w - w ~/ 2, h ~/ 2),
        crop(0, h ~/ 2, w ~/ 2, h - h ~/ 2),
        crop(w ~/ 2, h ~/ 2, w - w ~/ 2, h - h ~/ 2),
      ];
    }
  }

  /// 單一區域解碼（失敗回 null——回退是正常路徑，不拋錯）。
  static String? _decodeRegion(img.Image image) {
    try {
      final rgba = image.convert(numChannels: 4);
      final pixels = rgba
          .getBytes(order: img.ChannelOrder.abgr)
          .buffer
          .asInt32List();
      final source = RGBLuminanceSource(image.width, image.height, pixels);
      final bitmap = BinaryBitmap(HybridBinarizer(source));
      return QRCodeReader().decode(bitmap).text;
    } catch (_) {
      return null;
    }
  }
}
