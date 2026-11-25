/// html5-qrcode＋TwEin 的 JS 互操作實作（T83——web only）。
///
/// JS 面（web/index.html 載入 web/scan/）：
/// - `Html5Qrcode`（UMD 2.3.8）：`new Html5Qrcode(elementId, config)` →
///   `start(cameraIdOrConfig, config, onSuccess, onError)` → `stop()/clear()`；
///   補光經 `applyVideoConstraints({advanced:[{torch}]})`。
/// - `window.TwEin`（esbuild IIFE）：`safeParseLeftQr/safeParseRightQr/`
///   `safeParseInvoiceQr/parseBarcode`——dartify 後轉純 Dart。
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe'; // callMethod 需要

import 'package:web/web.dart' as web;

import 'html5qrcode_scanner.dart';

/// html5-qrcode formatsToSupport enum 數值（套件定義順序）。
const int _fmtQrCode = 0;
const int _fmtCode39 = 3;
const int _fmtCode128 = 5;

@JS('Html5Qrcode')
extension type _Html5QrcodeJs._(JSObject _) implements JSObject {
  external _Html5QrcodeJs(String elementId, [JSObject? config]);
  external JSPromise start(
      JSAny cameraIdOrConfig, JSObject config, JSFunction onSuccess,
      [JSFunction? onError]);
  external JSPromise stop();
  external JSPromise clear();
  external JSAny? applyVideoConstraints(JSObject constraints);
  external JSObject? getRunningTrackCapabilities();
}

@JS()
external JSObject? get _html5QrcodeGlobal; // window.Html5Qrcode（UMD）

@JS('TwEin')
external JSObject? get _twEinGlobal; // window.TwEin（IIFE 全域）

class Html5QrScannerImpl implements Html5QrScanner {
  Html5QrScannerImpl();

  _Html5QrcodeJs? _scanner;
  bool _torchOn = false;

  @override
  bool get jsLoaded =>
      _html5QrcodeGlobal != null && _twEinGlobal != null;

  @override
  Future<void> start({
    required String elementId,
    required void Function(String text) onDecoded,
  }) async {
    final lib = _html5QrcodeGlobal;
    if (lib == null) {
      throw StateError('html5-qrcode 未載入（web/scan/ 資源缺失）');
    }
    _scanner = _Html5QrcodeJs(
      elementId,
      {'verbose': false}.jsify() as JSObject,
    );
    final config = {
      'fps': 10,
      'qrbox': {'width': 250, 'height': 250},
      'formatsToSupport': [_fmtQrCode, _fmtCode39, _fmtCode128],
    }.jsify() as JSObject;
    await _scanner!.start(
      ({'facingMode': 'environment'}.jsify() as JSObject),
      config,
      ((String decodedText, JSObject? _) {
        onDecoded(decodedText);
      }).toJS,
      ((String _ /* errorMessage */) {}).toJS, // 每幀失敗（未偵測）＝正常雜訊。
    ).toDart;
  }

  @override
  Future<void> stop() async {
    final scanner = _scanner;
    if (scanner == null) return;
    try {
      await scanner.stop().toDart;
      await scanner.clear().toDart;
    } catch (_) {
      // 已停（重入）——靜默。
    }
    _scanner = null;
    _torchOn = false;
  }

  @override
  bool get torchSupported => _scanner != null; // 開關內靜默處理不支援情況。

  @override
  bool get torchOn => _torchOn;

  @override
  void registerReaderView(String viewType) {
    // 直接建立 container div（html5-qrcode 需要 element 存在才能 start）。
    final div = web.document.getElementById('ls-h5q-reader');
    if (div == null) {
      final newDiv = (web.document.createElement('div') as web.HTMLDivElement)
        ..id = 'ls-h5q-reader'
        ..style.width = '100%'
        ..style.height = '100%';
      web.document.body?.append(newDiv);
    }
  }

  @override
  Future<bool> checkReaderDivReady(String elementId) async {
    try {
      final div = web.document.getElementById(elementId);
      if (div == null) return false;
      // 檢查 div 是否在 DOM 樹中且有尺寸
      final rect = div.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> toggleTorch() async {
    final scanner = _scanner;
    if (scanner == null) return;
    try {
      final p = scanner
          .applyVideoConstraints({
            'advanced': [
              {'torch': !_torchOn}
            ],
          }.jsify() as JSObject);
      // applyVideoConstraints 回傳 Promise（JS 執行期）——以 isA 檢查後等待。
      if (p.isA<JSPromise<JSAny?>>()) {
        await (p as JSPromise<JSAny?>).toDart;
      }
      _torchOn = !_torchOn;
    } catch (_) {
      // 無補光能力——靜默。
    }
  }

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

    final jsResult = _callJs(tw, 'safeParseInvoiceQr', [
      left,
      right,
      ?(barcode == null
          ? null
          : {'barcode': barcode}.jsify()),
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

  /// 呼叫 TwEin 任意方法（回 JSAny?）。
  JSAny? _callJs(JSObject tw, String method, List<Object?> args) {
    return tw.callMethod<JSAny?>(method.toJS, args.jsify());
  }
}

final Html5QrScanner html5QrScanner = Html5QrScannerImpl();
