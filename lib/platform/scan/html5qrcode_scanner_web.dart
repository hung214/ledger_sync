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
import 'dart:ui_web' as ui_web; // platformViewRegistry（reader div 掛載）

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
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

@JS('Html5Qrcode')
external JSObject? get _html5QrcodeGlobal; // window.Html5Qrcode（UMD）。
// **T84 根因②**：原寫法 `@JS()`（空名）——dart2js 對私有成員剝除底線解析成
// `window.html5QrcodeGlobal`（不存在）→ jsLoaded 恆 false → 掃描器永不啟動
//（PM「還沒辦法掃描發票」直接根因）。JS 互操作全域一律用顯式名稱。

@JS('TwEin')
external JSObject? get _twEinGlobal; // window.TwEin（IIFE 全域）

class Html5QrScannerImpl implements Html5QrScanner {
  Html5QrScannerImpl();

  _Html5QrcodeJs? _scanner;
  bool _torchOn = false;
  String _facing = 'environment'; // 目前鏡頭（pwa-0.5.2 切換鏡頭按鈕）。
  int _frameCount = 0; // 已處理幀數（每幀回呼——未偵測也計）。
  String? _lastElementId; // switchCamera 重啟參數（最後一次 start）。
  void Function(String text)? _lastOnDecoded;

  // === iOS PWA 相機管線保護（T84；移植 camera_stream_web T65 架構——
  // PM 2026-11-23 實測：session 內已啟動相機一旦停軌＝管線毒化，之後
  // 所有 getUserMedia 皆黑畫面，只有整頁重載可恢復。桌面 Chrome 無此
  // 限制——僅 iOS 設停軌標記，重進掃描頁觸發整頁重載＋自動回掃描）。
  static const String _kReopenFlag = 'ls_scan_reopen';
  static const String _kPendingScan = 'ls_pending_scan';
  static const String _kFacingKey = 'ls_scan_facing';
  bool _wasLive = false; // stop 時相機是否為活軌（毒化風險）

  // reader div（session 唯一；platform view 工廠回傳同一元素——
  // 重進掃描頁由新 HtmlElementView 重新掛載，與 shared video 同款）。
  static web.HTMLDivElement? _sharedReader;
  static bool _factoryRegistered = false;

  @override
  bool get jsLoaded =>
      _html5QrcodeGlobal != null && _twEinGlobal != null;

  @override
  String get facingLabel => _facing;

  @override
  int get frameCount => _frameCount;

  @override
  Future<void> start({
    required String elementId,
    required void Function(String text) onDecoded,
  }) async {
    final lib = _html5QrcodeGlobal;
    if (lib == null) {
      throw StateError('html5-qrcode 未載入（web/scan/ 資源缺失）');
    }
    _lastElementId = elementId;
    _lastOnDecoded = onDecoded;
    // 上次離開掃描頁停了活相機（iOS 管線已毒化）→ 整頁重載取乾淨
    // context；重載完成後 MainShellPage 讀 pending 旗標自動回掃描頁。
    // reload 後本 Future 永不完成（頁面已卸載）。
    try {
      if (web.window.sessionStorage.getItem(_kReopenFlag) != null) {
        web.window.sessionStorage.removeItem(_kReopenFlag);
        web.window.sessionStorage.setItem(_kPendingScan, '1');
        web.window.location.reload();
        return;
      }
    } catch (_) {/* sessionStorage 不可用——照原流程 */}
    // facing 跨重載保留（切換鏡頭＝整頁重載式，T65 架構）。
    try {
      final stored = web.window.sessionStorage.getItem(_kFacingKey);
      if (stored != null) {
        web.window.sessionStorage.removeItem(_kFacingKey);
        _facing = stored;
      }
    } catch (_) {}
    _scanner = _Html5QrcodeJs(
      elementId,
      {'verbose': false}.jsify() as JSObject,
    );
    // qrbox＝掃描窗（短邊 70%——與 APP 中央 70% 同款；發票 QR 為高密度
    // V13，窗越大越易解）。videoConstraints：facing（ideal——被忽略不炸）
    // ＋高解析度取像（解碼距離——低解析度是「掃不到」主因，T65 教訓）。
    final config = {
      'fps': 10,
      'qrbox': ((num vw, num vh) {
        final side = ((vw < vh ? vw : vh) * 0.7).floor();
        return {'width': side, 'height': side}.jsify();
      }).toJS,
      'videoConstraints': {
        'facingMode': {
          'ideal': _facing,
        },
        'width': {'ideal': 1920},
        'height': {'ideal': 1080},
      }.jsify(),
      'formatsToSupport': [_fmtQrCode, _fmtCode39, _fmtCode128],
    }.jsify() as JSObject;
    await _scanner!.start(
      ({'facingMode': _facing}.jsify() as JSObject),
      config,
      ((String decodedText, JSObject? _) {
        onDecoded(decodedText);
      }).toJS,
      ((String _ /* errorMessage */) {
        _frameCount++; // 每幀失敗（未偵測）＝正常雜訊——計入幀數流動。
      }).toJS,
    ).toDart;
    _wasLive = true;
  }

  @override
  Future<void> switchCamera() async {
    if (_scanner == null || _lastElementId == null) return; // 未啟動——靜默。
    final prev = _facing;
    await stop();
    _facing = prev == 'environment' ? 'user' : 'environment';
    try {
      web.window.sessionStorage.setItem(_kFacingKey, _facing);
    } catch (_) {}
    try {
      // iOS：stop 已設 reopen 旗標 → start() 走整頁重載式切換（T65——
      // 毒化管線唯一可靠路徑）。桌面：同 session 直接重啟（秒切）。
      await start(elementId: _lastElementId!, onDecoded: _lastOnDecoded!);
    } catch (_) {
      _facing = prev; // 切換失敗——回復原鏡頭（重試可回後鏡頭）。
      rethrow;
    }
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
    // iOS：停了活相機＝管線毒化 → 標記「重進需整頁重載」（T65——
    // PM 驗證可靠的唯一恢復路徑）。桌面 Chrome 無毒化問題，不標記。
    if (_wasLive && defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        web.window.sessionStorage.setItem(_kReopenFlag, '1');
      } catch (_) {}
    }
    _wasLive = false;
  }

  @override
  bool get torchSupported => _scanner != null; // 開關內靜默處理不支援情況。

  @override
  bool get torchOn => _torchOn;

  @override
  void registerReaderView(String viewType) {
    // **T84 根因修復**：reader div 必須掛在 **Flutter 樹內**（HtmlElementView
    // platform view）——T83 直接 append 到 document.body 會讓 html5-qrcode
    // 的 video 渲染在 App 畫布之外（video 出現在頁面末端＝整頁 UI 破版、
    // 掃描框與畫面錯位）。與 camera_stream_web 的 shared video 同款：
    // session 單一元素，重進掃描頁由新 HtmlElementView 重掛同一元素。
    _sharedReader ??=
        (web.document.createElement('div') as web.HTMLDivElement)
          ..id = 'ls-h5q-reader'
          ..style.width = '100%'
          ..style.height = '100%';
    if (!_factoryRegistered) {
      ui_web.platformViewRegistry.registerViewFactory(
          viewType, (int viewId) => _sharedReader!);
      _factoryRegistered = true;
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

    // **T84**：右碼未掃到＝「省略參數」（官方契約 parseInvoiceQr(left,
    // right?)——實測傳 null 會 INVALID_INPUT「right QR must be a string」，
    // 導致單左碼發票永遠走不到 TwEin）。左碼明細未齊（itemCount 未滿）時
    // TwEin 回 INCOMPLETE_ITEMS → 呼叫端等右碼進累積窗／後備解析器接手。
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
  /// **T84 修復**：`callMethod` 是「最多 4 個位置參數」而非 List——原寫法
  /// 把整個 jsified List 當成第一個參數傳入 → TwEin 收到陣列而非字串
  /// → INVALID_INPUT「left QR must be a string」（TwEin 主路徑全滅，
  /// 永遠只剩後備解析器）。改用 callMethodVarArgs 正確展開。
  JSAny? _callJs(JSObject tw, String method, List<JSAny?> args) {
    return tw.callMethodVarArgs<JSAny?>(method.toJS, args);
  }
}

final Html5QrScanner html5QrScanner = Html5QrScannerImpl();
