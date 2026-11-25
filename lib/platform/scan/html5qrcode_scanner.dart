/// html5-qrcode 掃描器＋@hsuan741220/tw-einvoice-qr 發票解析（T83，PM
/// 2026-11-24 指示——PWA 掃描技術替換；回退保險＝tag `pwa-0.5.2`）。
///
/// 兩個 JS 套件由 web/index.html 同步載入（本地資源 web/scan/）：
/// - `window.Html5Qrcode`（UMD 2.3.8）——相機連續掃描（自帶取幀/解碼迴圈）
/// - `window.TwEin`（esbuild IIFE）——台灣電子發票官方規格 v1.9 完整解析
///   （左右雙 QR／Code 39／77 碼欄位／品目／Base64／境外電商）
///
/// **解析合約**：`parseInvoice(texts)` 接受累積窗的條碼文字清單（左碼／
/// 右碼／Code 39 混合），內部分類後走 `safeParseInvoiceQr(left, right,
/// {barcode})`——回傳**純 Dart** 結構（呼叫端不碰 JS）。
///
/// 條件匯出（stub 保 native 編譯——web_camera_scan 在 VM 測試可載）。
library;

export 'html5qrcode_scanner_stub.dart'
    if (dart.library.js_interop) 'html5qrcode_scanner_web.dart';

/// TwEin 發票解析結果（純 Dart）。
class TwEinInvoice {
  const TwEinInvoice({
    required this.invoiceNumber,
    required this.date,
    required this.totalAmountMinor,
    this.sellerTaxId,
    this.randomCode,
    this.items = const [],
  });

  final String? invoiceNumber;

  /// 開立日（TwEin ISO date）。
  final DateTime? date;

  /// 含稅總額（**minor**＝元×100——TWD zero-decimal，min）
  final int totalAmountMinor;
  final String? sellerTaxId;
  final String? randomCode;

  /// 明細（TwEin items——名稱/數量/單價）。
  final List<TwEinItem> items;
}

class TwEinItem {
  const TwEinItem({required this.name, required this.quantity, required this.unitPrice});

  final String name;
  final num quantity;
  final num unitPrice;
}

/// html5-qrcode 掃描器介面（web 實作；stub 靜默）。
abstract class Html5QrScanner {
  /// JS 套件是否已載入（index.html script——檔案缺失/載入失敗＝false）。
  bool get jsLoaded;

  /// 啟動相機連續掃描（html5-qrcode 自管取幀與解碼迴圈）。
  /// [elementId]＝掛載 div（platform view 注入 DOM）。
  /// [onDecoded]＝每筆解碼文字（不限發票——呼叫端累積/分類）。
  Future<void> start({
    required String elementId,
    required void Function(String text) onDecoded,
  });

  /// 停止掃描並清理（離開頁面必呼——釋放相機）。
  Future<void> stop();

  /// 補光能力（running track capabilities 有 torch）。
  bool get torchSupported;

  /// 目前補光狀態（UI 圖示用）。
  bool get torchOn;

  /// 註冊 reader div platform view（[viewType]——掃描區 HtmlElementView）。
  void registerReaderView(String viewType);

  /// 補光切換（不支援＝靜默）。
  Future<void> toggleTorch();

  /// 台灣發票解析（TwEin）——[texts] 為累積窗條碼文字；無法組出完整
  /// 發票（缺左碼等）回 null（呼叫端引導對準另一碼）。
  TwEinInvoice? parseInvoice(List<String> texts);

  /// 檢查 reader div 是否已進入 DOM（html5-qrcode 需要 element 存在＋有尺寸）。
  Future<bool> checkReaderDivReady(String elementId);

  /// 切換鏡頭（前/後；pwa-0.5.2 版面按鈕——`webcam-switch-camera`）。
  /// 未啟動＝靜默；iOS 走整頁重載式切換（T65——毒化管線唯一可靠路徑，
  /// facing 存 sessionStorage 跨重載）；桌面同 session 直接重啟。
  Future<void> switchCamera();

  /// 目前鏡頭 facing（'environment'／'user'——診斷面板顯示）。
  String get facingLabel;

  /// 已處理幀數（html5-qrcode 每幀回呼——未偵測也計；診斷「幀數流動」）。
  int get frameCount;
}
