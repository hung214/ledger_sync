/// @hsuan741220/tw-einvoice-qr 發票解析層（T85——PM 2026-11-25 指示
/// 「回到 pwa-0.5.2 重新處理」：掃描引擎回歸 pwa-0.5.2 架構
/// [camera_stream.dart]（BarcodeDetector 原生偵測＋zxing2 後備——PM
/// 驗證過的鏡頭管理），**TwEin 官方解析保留疊加**（解析與引擎無關——
/// 解出的條碼文字丟給 TwEin 組發票）。
///
/// JS 面：`window.TwEin`（esbuild IIFE，web/index.html 同步載入
/// web/scan/tw-einvoice.js）——台灣電子發票官方規格 v1.9 完整解析
/// （左右雙 QR／Code 39／77 碼欄位／品目／Base64／境外電商）。
///
/// **解析合約**：[TwEinParser.parseInvoice] 接受累積窗的條碼文字清單
/// （左碼／右碼／Code 39 混合），內部分類後走
/// `safeParseInvoiceQr(left, right?, {barcode})`——回傳**純 Dart** 結構
/// （呼叫端不碰 JS）。
///
/// 條件匯出（stub 保 native 編譯——web_camera_scan 在 VM 測試可載）。
library;

export 'tw_ein_parse_stub.dart' if (dart.library.js_interop) 'tw_ein_parse_web.dart';

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

  /// 含稅總額（**minor**＝台幣元——TWD zero-decimal，勿再 ×100）
  final int totalAmountMinor;
  final String? sellerTaxId;
  final String? randomCode;

  /// 明細（TwEin items——名稱/數量/單價）。
  final List<TwEinItem> items;
}

class TwEinItem {
  const TwEinItem({
    required this.name,
    required this.quantity,
    required this.unitPrice,
  });

  final String name;
  final num quantity;
  final num unitPrice;
}

/// TwEin 解析器介面（web 實作；stub 靜默回 null）。
abstract class TwEinParser {
  const TwEinParser();

  /// 台灣發票解析（TwEin）——[texts] 為累積窗條碼文字；無法組出完整
  /// 發票（缺左碼等）回 null（呼叫端引導對準另一碼／後備解析器接手）。
  TwEinInvoice? parseInvoice(List<String> texts);
}
