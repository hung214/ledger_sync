/// TwEin 的 JS 互操作實作（web only；T85 自 html5qrcode_scanner_web
/// 抽出——解析層與掃描引擎解耦，掃描引擎回歸 pwa-0.5.2 架構）。
///
/// JS 面：`window.TwEin`（esbuild IIFE）——`safeParseLeftQr/`
/// `safeParseRightQr/safeParseInvoiceQr/parseBarcode`，dartify 後轉純 Dart。
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe'; // callMethodVarArgs 需要

import 'tw_ein_parse.dart';

@JS('TwEin')
external JSObject? get _twEinGlobal; // window.TwEin（IIFE 全域）

/// 全域實例（頁面經 Riverpod provider 包一層——測試可覆寫 fake）。
const TwEinParser twEinParser = TwEinParserImpl();

class TwEinParserImpl implements TwEinParser {
  const TwEinParserImpl();

  @override
  TwEinInvoice? parseInvoice(List<String> texts) {
    final tw = _twEinGlobal;
    if (tw == null || texts.isEmpty) return null;

    // 分類（TwEin safeParse* 為準——不自行猜格式）。
    String? left, right, barcode;
    for (final t in texts) {
      if (left == null &&
          (t.length >= 77 || RegExp(r'^[0-9A-Z]{26,}').hasMatch(t))) {
        if (_callSafe(tw, 'safeParseLeftQr', t)) {
          left = t;
          continue;
        }
      }
      if (right == null && t.startsWith('**')) {
        if (_callSafe(tw, 'safeParseRightQr', t)) {
          right = t;
          continue;
        }
      }
      if (barcode == null &&
          RegExp(r'^\*?[0-9]{3}[A-Z]{2}[0-9]{8}[0-9]{4}\*?$').hasMatch(t)) {
        if (_callSafe(tw, 'safeParseBarcode', t)) {
          barcode = t;
          continue;
        }
      }
    }
    if (left == null) return null; // 左碼＝發票身分——缺左碼無法組發票。

    // **右碼未掃到＝「省略參數」**（官方契約 parseInvoiceQr(left, right?)——
    // 實測傳 null 會 INVALID_INPUT「right QR must be a string」，導致單左碼
    // 發票永遠走不到 TwEin）。左碼明細未齊（itemCount 未滿）時 TwEin 回
    // INCOMPLETE_ITEMS → 呼叫端等右碼進累積窗／後備解析器接手。
    final jsResult = right == null
        ? _callJs(tw, 'safeParseInvoiceQr', [left.toJS])
        : _callJs(tw, 'safeParseInvoiceQr', [
            left.toJS,
            right.toJS,
            ?(barcode == null ? null : {'barcode': barcode}.jsify()),
          ]);
    if (jsResult == null) return null;
    final dart = jsResult.dartify() as Map<Object?, Object?>;
    if (dart['success'] != true) return null;
    final data = dart['data'];
    if (data is! Map) return null;

    final items = <TwEinItem>[
      if (data['items'] is List)
        for (final it in data['items'] as List)
          if (it is Map)
            TwEinItem(
              name: '${it['name'] ?? ''}',
              quantity: (it['quantity'] as num?) ?? 0,
              unitPrice: (it['unitPrice'] as num?) ?? 0,
            ),
    ];
    final dateStr = data['date']?.toString();
    DateTime? date;
    if (dateStr != null) {
      date = DateTime.tryParse(dateStr);
    }
    final total = (data['totalAmount'] as num?) ?? 0;
    return TwEinInvoice(
      invoiceNumber: data['invoiceNumber']?.toString(),
      date: date,
      // TWD zero-decimal：TwEin 回元——minor＝元（勿 ×100，PM 2026-11-24 指正）。
      totalAmountMinor: total.round(),
      sellerTaxId: data['sellerIdentifier']?.toString(),
      randomCode: data['randomCode']?.toString(),
      items: items,
    );
  }

  /// 呼叫 TwEin safeParse*（回 bool——success 欄位）。
  bool _callSafe(JSObject tw, String method, String arg) {
    final result = tw.callMethod<JSAny?>(method.toJS, arg.toJS);
    final dart = result?.dartify();
    return dart is Map && dart['success'] == true;
  }

  /// 呼叫 TwEin 任意方法（參數已轉 JS 值）。
  /// **T84 教訓**：`callMethod` 是「最多 4 個位置參數」而非 List——把
  /// jsified List 當第一個參數傳入 → TwEin 收到陣列而非字串 →
  /// INVALID_INPUT「left QR must be a string」。必須用 callMethodVarArgs。
  JSAny? _callJs(JSObject tw, String method, List<JSAny?> args) {
    return tw.callMethodVarArgs<JSAny?>(method.toJS, args);
  }
}
