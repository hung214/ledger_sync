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

  /// **相機幀輕量解碼**（F14 web 迴圈專用）：只試**整張＋左右半**（3 區）。
  ///
  /// 相機迴圈每 1.2s 一幀、解碼在主執行緒**同步**跑（dart2js 單執行緒）——
  /// 完整 9 區掃描在行動裝置上每幀可達數秒，疊加後塞死 UI（PM 2026-11-21
  /// 「全部掃描失敗＋顯示不正常」根因）。發票雙碼左右同列，切半即可分別
  /// 解出（PM 2026-10-29 實測）；上下半/四象限留給檔案匯入完整掃。
  TransactionDraft? draftFromCameraFrame(Uint8List bytes, {DateTime? now}) =>
      draftFromQrTexts(decodeQrTexts(bytes, fullScan: false));

  /// 左碼字軌特徵（官方規格 v1.9：2 大寫字母＋8 數字）。
  static final RegExp _invoiceNoPattern = RegExp(r'[A-Z]{2}[0-9]{8}');

  /// 自解碼文字中**定位官方發票左碼**（財政部 v1.9）。
  ///
  /// 字軌 `[A-Z]{2}[0-9]{8}` 起始（前導雜訊 ≤4 字——Vision Byte-mode 標頭
  /// 殘留量級），自字軌起通過 [InvoiceQrParser.isValidOfficialLeft]（金額
  /// 十六進位＋日期＋Base64 加密驗證＋延伸區 `:` 規則）→ 回傳自字軌起之
  /// 子字串（含延伸區，常 90–130 字）。不合規（其他 App 條碼/斷碼）回
  /// null——**不硬湊 77 字**，避免組出錯誤交易。
  static String? extractOfficialLeft(String s) {
    for (final m in _invoiceNoPattern.allMatches(s)) {
      if (m.start > 4) break; // 前導雜訊超過標頭量級——非定位場景
      final candidate = s.substring(m.start);
      if (InvoiceQrParser.isValidOfficialLeft(candidate)) return candidate;
    }
    return null;
  }

  /// 由 QR 文字組出發票草稿——**官方規格（財政部 v1.9）優先**，舊內部測資
  /// 格式（SDD §5.4；deflate+Base32 右碼）保留相容。
  ///
  /// PM 2026-11-22 根因修復：真實發票左碼＝77 碼固定區＋`:` 延伸區（金額
  /// **十六進位**、常 90–130 字）——舊 `length==77＋十進位` 規則把真實發票
  /// 全數拒絕（僅內部測資可過）。
  static TransactionDraft? draftFromQrTexts(List<String> texts) {
    String? officialLeft;
    String? officialRight;
    String? legacyLeft;
    String? legacyRight;
    for (final t in texts) {
      final l = extractOfficialLeft(t);
      if (l != null) {
        officialLeft ??= l;
        continue;
      }
      if (t.startsWith('**')) {
        officialRight ??= t;
        continue;
      }
      // 舊內部測資格式（SDD §5.4）——右碼為 deflate+Base32（無 `**` 前綴）。
      if (t.length == 77) {
        legacyLeft ??= t;
      } else {
        legacyRight ??= t;
      }
    }
    if (officialLeft != null) {
      return InvoiceQrParser.parseOfficial(officialLeft, officialRight);
    }
    if (legacyLeft != null) {
      return legacyRight == null
          ? InvoiceQrParser.parseLeft(legacyLeft)
          : InvoiceQrParser.parse(legacyLeft, legacyRight);
    }
    return null;
  }

  /// 解出影像中所有 QR 文字（去重、最多 [_maxCodes] 個）。
  ///
  /// 每區先以原尺寸解碼；失敗且區域過大（最長邊 > [_maxDecodeDim]）時
  /// **降採樣重試**——zxing2 對大圖/長邊區域易失靈（PM 2026-11-22 實測：
  /// 手機直式相機幀 1080×1920、實拍照片 3000×4000 的整張/切半皆解不出，
  /// 降採樣至 ≤800 後全數可解，且解碼更快）。小 QR 照片不受影響——原尺寸
  /// 先行，降採樣僅為後備。
  ///
  /// `fullScan = false` → 只試**整張＋左右半**（相機幀輕量模式——
  /// 行動裝置主執行緒同步解碼，區域數直接決定每幀耗時）。
  static List<String> decodeQrTexts(Uint8List bytes, {bool fullScan = true}) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return const [];
    final found = <String>[];
    for (final region in _regions(decoded, fullScan: fullScan)) {
      final text = _decodeRegion(region) ?? _decodeDownscaled(region);
      if (text != null && !found.contains(text)) found.add(text);
      if (found.length >= _maxCodes) break;
    }
    return found;
  }

  static const int _maxCodes = 4;

  /// 區域解碼之降採樣後備上限（最長邊）。
  static const int _maxDecodeDim = 800;

  static String? _decodeDownscaled(img.Image region) {
    final maxDim = region.width > region.height ? region.width : region.height;
    if (maxDim <= _maxDecodeDim) return null;
    final scale = _maxDecodeDim / maxDim;
    final small = img.copyResize(region,
        width: (region.width * scale).round(),
        height: (region.height * scale).round());
    return _decodeRegion(small);
  }

  /// 嘗試區域：整張 → 左／右半 →（完整掃才續）上／下半 → 四象限
  /// （發票雙 QR 多在左右）。
  static Iterable<img.Image> _regions(img.Image src,
      {bool fullScan = true}) sync* {
    final w = src.width;
    final h = src.height;
    img.Image crop(int x, int y, int cw, int ch) =>
        img.copyCrop(src, x: x, y: y, width: cw, height: ch);

    yield src;
    if (w >= 40) {
      yield crop(0, 0, w ~/ 2, h);
      yield crop(w ~/ 2, 0, w - w ~/ 2, h);
    }
    if (!fullScan) return; // 相機輕量模式：整張＋左右半即止
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
