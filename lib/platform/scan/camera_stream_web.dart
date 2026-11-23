import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'camera_stream.dart';

/// 瀏覽器**原生 BarcodeDetector API**（T10，PM 2026-11-22「Mac PWA 還是
/// 無法讀取」主修法）：Chrome/Edge/Safari 17+ 內建——品質遠勝 zxing2，
/// 直接吃 `<video>` 全解析度幀（無 canvas/JPEG 轉檔損耗）。
@JS('BarcodeDetector')
external JSObject? get _barcodeDetectorCtor; // feature detection 用

@JS('BarcodeDetector')
extension type _BarcodeDetector._(JSObject _) implements JSObject {
  external _BarcodeDetector(JSObject options);
  external JSPromise<JSArray<_BarcodeResultJS>> detect(JSObject source);
}

extension type _BarcodeResultJS._(JSObject _) implements JSObject {
  external JSString? get rawValue;
}

/// web（PWA）相機控制器：`getUserMedia`（後鏡頭）＋`<video>` 預覽＋canvas 取幀。
///
/// - 需 **https**（或 localhost）——瀏覽器權限要求。
/// - 預覽以 `HtmlElementView` 嵌入（`ui_web.platformViewRegistry` 註冊）。
/// - 取幀＝video 畫到 canvas → JPEG bytes（品質 0.8）→ 交 zxing2 解碼。
///
/// iOS Safari 限制與對策（DBG-018；PM 2026-11-21）：
/// - facingMode 約束可能被忽略（WebKit 252560/253186）→ 授權後
///   `enumerateDevices` 選後鏡頭：標籤提示優先（會**在地化**，僅作提示），
///   **順序慣例次之**（iOS 第一個 videoinput＝前鏡頭、第二個＝後鏡頭），
///   以 deviceId 精選切換。
/// - 背景/退出後軌跡被系統結束 → 黑畫面（WebKit 239849/275527）→
///   `visibilitychange` 偵測死亡軌跡，自動停舊重取。
class WebCameraStreamController implements CameraStreamController {
  web.HTMLVideoElement? _video;
  web.MediaStream? _stream;
  web.EventHandler? _visibilityHandler;
  String _facing = 'environment'; // 目前鏡頭朝向（切換按鈕用）
  String? _switchNote; // 診斷：最近一次切換的結果（面板顯示）
  bool _torchOn = false; // 補光狀態

  @override
  String get diagInfo =>
      'facing=$_facing${_switchNote == null ? '' : '｜$_switchNote'}';

  @override
  String get resolutionInfo {
    final v = _video;
    return (v == null || v.videoWidth == 0)
        ? ''
        : '${v.videoWidth}x${v.videoHeight}';
  }

  _BarcodeDetector? _nativeDetector;

  @override
  bool get hasNativeBarcodeDetector => _barcodeDetectorCtor != null;

  _BarcodeDetector? _getNativeDetector() {
    if (!hasNativeBarcodeDetector) return null;
    try {
      return _nativeDetector ??= _BarcodeDetector(({
        'formats': ['qr_code', 'code_39', 'code_128'],
      }).jsify()! as JSObject);
    } catch (_) {
      return null; // 構造失敗（不支援的格式等）——退回 zxing2 後備。
    }
  }

  @override
  Future<List<String>> detectNativeBarcodes() async {
    final v = _video;
    final detector = _getNativeDetector();
    if (v == null || v.videoWidth == 0 || detector == null) return const [];
    try {
      final results = await detector.detect(v).toDart;
      return [
        for (final r in results.toDart) r.rawValue?.toDart ?? '',
      ].where((t) => t.isNotEmpty).toList();
    } catch (_) {
      return const []; // 偵測失敗——退回 zxing2 後備（呼叫端分流）。
    }
  }

  @override
  bool get torchSupported => true; // 先顯示開關；toggleTorch 內靜默處理不支援情況

  @override
  bool get torchOn => _torchOn;

  @override
  Future<void> toggleTorch() async {
    try {
      final tracks = _stream?.getVideoTracks().toDart;
      if (tracks == null || tracks.isEmpty) return;
      final track = tracks.first;
      // 嘗試切換 torch：applyConstraints advanced [{torch: !_torchOn}]
      // 無補光能力或相機未啟動 → applyConstraints 拋錯 → 靜默。
      final advanced = <web.MediaTrackConstraintSet>[
        web.MediaTrackConstraintSet(torch: (!_torchOn).toJS),
      ].toJS;
      await track
          .applyConstraints(web.MediaTrackConstraints(advanced: advanced))
          .toDart;
      _torchOn = !_torchOn;
    } catch (_) {
      // 無補光能力或相機未啟動——靜默。
    }
  }

  static int _seq = 0;
  late final String _viewType = 'webcam-${_seq++}';
  static DateTime? _lastDisposeAt; // 跨實例：退出重進的釋放等待基準

  @override
  Future<Widget> start() async {
    final video = (web.document.createElement('video') as web.HTMLVideoElement)
      ..autoplay = true
      ..muted = true
      ..playsInline = true;
    _video = video;
    ui_web.platformViewRegistry.registerViewFactory(
        _viewType, (int viewId) => video);
    try {
      // iOS PWA：退出重進的黑畫面（WebKit 275527 同族；wildhart workaround）
      // ——① 等 session 釋放（≥600ms）② 暖機呼叫重置相機狀態。
      final last = _lastDisposeAt;
      if (last != null) {
        final elapsed = DateTime.now().difference(last);
        const wait = Duration(milliseconds: 600);
        if (elapsed < wait) {
          await Future.delayed(wait - elapsed);
        }
      }
      _lastDisposeAt = null;
      final md = web.window.navigator.mediaDevices;
      try {
        final warm = await md
            .getUserMedia(web.MediaStreamConstraints(video: true.toJS))
            .toDart;
        for (final t in warm.getTracks().toDart) {
          t.stop();
        }
      } catch (_) {
        // 暖機失敗不阻擋——正式取得流程自行處理錯誤。
      }
      // 暖機後等 300ms（重進釋放保險）。
      await Future.delayed(const Duration(milliseconds: 300));
      await _openOn(video);
    } catch (e) {
      dispose();
      throw _classify(e);
    }
    // iOS：背景後軌跡被系統結束（WebKit 239849）——重回可見時自動重取。
    _attachVisibilityRevival(video);
    // 黑畫面看門狗——進入後自癒（PM：每次進入重新渲染鏡頭）。
    _healCount = 0;
    _startWatchdog(video);
    return HtmlElementView(viewType: _viewType);
  }

  /// 完整開機流程：取得後鏡頭串流 → 掛到 video → play。
  /// 開機世代（重進/切鏡頭/看門狗重取會遞增——舊驗證迴圈自動失效）。
  int _openGen = 0;

  Future<void> _openOn(web.HTMLVideoElement video) async {
    final gen = ++_openGen;
    _stopStreamTracks(); // 確保無殘留軌道（硬體鎖釋放後再取）
    _stream = await _acquireRearCamera();
    video.srcObject = _stream;
    // 初始/恢復一律後鏡頭——鏡像清除（防切換失敗殘留 scaleX(-1)，
    // PM 2026-11-21「顯示不正常」＝鏡像殘留疊在後鏡頭上）。
    video.style.setProperty('transform', 'none');
    try {
      await video.play().toDart;
    } catch (_) {
      // 自動播放政策攔截——loadedmetadata 事件會再補 play。
    }
    video.onloadedmetadata = ((web.Event e) {
      try {
        video.play().toDart.ignore();
      } catch (_) {}
    }).toJS;
    // **黑畫面驗證＋自癒**（PM 2026-11-23：退出重進掃描頁＝停軌後
    // iOS 相機管線未完全重置→重取得黑串流。取得後實際採樣驗證，
    // 黑 → 停、遞增延遲重取——背景進行不阻塞預覽掛載）。
    unawaited(_verifyAndHeal(video, gen));
  }

  /// 黑畫面驗證＋自癒迴圈：每輪採樣亮度，非黑即成功返回；黑 → 停軌、
  /// 清掛載、遞增延遲（400/800/1200ms）重取。世代不符（新開機）即退出。
  Future<void> _verifyAndHeal(web.HTMLVideoElement video, int gen) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      await Future.delayed(const Duration(milliseconds: 600));
      if (gen != _openGen || _video == null) return; // 已有更新開機/已退出
      if (video.readyState >= 2 && video.videoWidth > 0) {
        try {
          if (_sampleLuminance(video) > 4) return; // 幀流動 ✓
        } catch (_) {/* 採樣失敗——下輪再驗 */}
      }
      // 黑畫面 → 釋放＋重取（遞增延遲給 iOS 硬體更多重置時間）。
      _stopStreamTracks();
      video.srcObject = null;
      await Future.delayed(Duration(milliseconds: 400 + attempt * 400));
      if (gen != _openGen || _video == null) return;
      try {
        _stream = await _acquireRearCamera();
        video.srcObject = _stream;
        try {
          await video.play().toDart;
        } catch (_) {}
      } catch (_) {/* 重取失敗——下輪再試 */}
    }
  }

  /// 後鏡頭取得流程：
  /// 1. facingMode 鏈（exact→ideal→任一）——取得**權限**與初始串流；
  ///    部分裝置會忽略約束而開前鏡頭（WebKit 252560）。
  /// 2. deviceId 精選——enumerateDevices 選出後鏡頭（標籤提示 → iOS 順序
  ///    慣例），與目前串流不同時停舊重取。
  Future<web.MediaStream> _acquireRearCamera() async {
    final md = web.window.navigator.mediaDevices;
    var stream = await _tryGetUserMedia(md, const {
      'facingMode': {'exact': 'environment'},
    })
        .catchError((_) => _tryGetUserMedia(md, const {
              'facingMode': {'ideal': 'environment'},
            }))
        .catchError((_) => _tryGetUserMedia(md, null));
    try {
      final rearId = await _pickRearDeviceId(md);
      if (rearId != null && rearId.isNotEmpty) {
        final tracks = stream.getVideoTracks().toDart;
        final currentId =
            tracks.isNotEmpty ? tracks.first.getSettings().deviceId : null;
        if (currentId != rearId) {
          for (final t in stream.getTracks().toDart) {
            t.stop();
          }
          // iOS：session 釋放需時間——立即重取會拿到同一顆/黑畫面。
          await Future.delayed(const Duration(milliseconds: 600));
          stream = await md.getUserMedia(web.MediaStreamConstraints(
              video: {
            'deviceId': {'exact': rearId},
          }.jsify()!)).toDart;
        }
      }
    } catch (_) {
      // 精選失敗——沿用第一階段串流（不阻擋預覽）。
    }
    _facing = 'environment';
    return stream;
  }

  Future<web.MediaStream> _tryGetUserMedia(
      web.MediaDevices md, Map<String, Object>? facing) {
    // width/height ideal：拉高取像解析度（預設常 640×480——
    // 解碼距離不足的主因，PM 2026-11-21「無法正確掃描」）。
    final hiRes = {
      'width': {'ideal': 1920},
      'height': {'ideal': 1080},
    };
    final video = facing == null
        ? hiRes.jsify()!
        : {
            'facingMode': facing,
            ...hiRes,
          }.jsify()!;
    return md.getUserMedia(web.MediaStreamConstraints(video: video)).toDart;
  }

  /// 切換相機（PM 2026-11-21 按鈕需求）：前↔後以 **facingMode 精選**——
  /// PM 裝置已證實會遵守（後鏡頭由此機制開啟）；deviceId 約束於 iOS
  /// session 釋放競態下會被忽略（PM 實測「切換沒效」）。
  /// 流程：停軌跡（凍結現有畫面，不黑屏）→ 等 session 釋放 → facing 精選
  /// → 前鏡頭加鏡像（自拍慣例）。每步結果寫入 _switchNote（面板顯示）。
  @override
  Future<void> switchCamera() async {
    final video = _video;
    if (video == null) {
      _switchNote = '✗無video';
      return;
    }
    try {
      final target = _facing == 'user' ? 'environment' : 'user';
      _switchNote = '切換→$target…';
      for (final t in _stream?.getVideoTracks().toDart ?? const []) {
        t.stop();
      }
      await Future.delayed(const Duration(milliseconds: 600));
      web.MediaStream stream;
      try {
        stream = await _tryGetUserMedia(
            web.window.navigator.mediaDevices, {'exact': target});
        _switchNote = '✓exact→$target';
      } catch (e) {
        _switchNote = 'exact✗(${_brief(e)})→ideal…';
        stream = await _tryGetUserMedia(
            web.window.navigator.mediaDevices, {'ideal': target});
        _switchNote = '✓ideal→$target';
      }
      _stream = stream;
      _facing = target;
      video.srcObject = stream;
      // 前鏡頭鏡像（自拍慣例；擷取幀不鏡像——解碼不受影響）。
      video.style.setProperty(
          'transform', target == 'user' ? 'scaleX(-1)' : 'none');
      try {
        await video.play().toDart;
      } catch (_) {}
      _switchNote = '✓$target';
    } catch (e) {
      _switchNote = '✗${_brief(e)}';
      // 切換失敗自癒：重取後鏡頭（否則停軌後畫面凍結＋鏡像殘留）。
      video.style.setProperty('transform', 'none');
      try {
        await _openOn(video);
        _switchNote = '✗${_brief(e)}｜已回後鏡頭';
      } catch (_) {}
    }
  }

  String _brief(Object e) {
    final s = e.toString();
    return s.length > 48 ? s.substring(0, 48) : s;
  }

  /// 由 enumerateDevices 選出**後鏡頭** deviceId。
  /// - 標籤提示（back/rear/environment/後/背；**僅作提示**——標籤會在地化）
  /// - 無提示 → iOS 順序慣例：第一個 videoinput＝前、第二個＝後
  ///   （僅 iOS 套用——桌面多 webcam 不適用）。
  /// - 副鏡頭（ultra/tele/廣角/望遠）排在主鏡頭之後。
  Future<String?> _pickRearDeviceId(web.MediaDevices md) async {
    final devices = await md.enumerateDevices().toDart;
    final videoInputs = [
      for (final d in devices.toDart)
        if (d.kind == 'videoinput') d,
    ];
    if (videoInputs.isEmpty) return null;
    final hinted = [
      for (final d in videoInputs)
        if (_looksLikeRear(d.label)) d,
    ];
    if (hinted.isNotEmpty) {
      for (final d in hinted) {
        final l = d.label.toLowerCase();
        final isAux = l.contains('ultra') ||
            l.contains('tele') ||
            l.contains('廣角') ||
            l.contains('望遠');
        if (!isAux) return d.deviceId;
      }
      return hinted.first.deviceId;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        videoInputs.length >= 2) {
      return videoInputs[1].deviceId;
    }
    return null;
  }

  bool _looksLikeRear(String label) {
    final l = label.toLowerCase();
    return l.contains('back') ||
        l.contains('rear') ||
        l.contains('environment') ||
        l.contains('後') ||
        l.contains('背');
  }

  /// iOS：背景時 WebKit 凍結串流但**不釋放硬體鎖**——舊串流殘留＝
  /// 重回前景黑畫面（PM 2026-11-23 研究確認）。生命週期對策：
  /// - **hidden：立刻停軌＋清 srcObject**（釋放相機硬體，不留殘屍）。
  /// - **visible：延遲 300ms**（等 iOS 動畫＋硬體釋放）→ 重取串流。
  void _attachVisibilityRevival(web.HTMLVideoElement video) {
    _visibilityHandler = ((web.Event e) {
      if (web.document.visibilityState == 'visible') {
        // 前景：延遲後重取（硬體釋放需要時間）。
        Future.delayed(const Duration(milliseconds: 300), () async {
          // 掃描頁已退出（dispose 清掉）→ 不重取。
          if (_video == null) return;
          _stopStreamTracks();
          try {
            await _openOn(video);
          } catch (_) {
            // 重取失敗（權限/硬體忙碌）——看門狗會再自癒。
          }
        });
      } else {
        // 背景：立刻釋放（停軌＋清 srcObject——不留硬體鎖）。
        _stopStreamTracks();
        video.srcObject = null;
      }
    }).toJS;
    web.document.addEventListener('visibilitychange', _visibilityHandler!);
  }

  /// 停止目前串流所有軌道（釋放相機硬體鎖）。
  void _stopStreamTracks() {
    for (final t in _stream?.getVideoTracks().toDart ?? const []) {
      t.stop();
    }
  }

  @override
  Future<Uint8List?> captureFrame() async {
    final v = _video;
    if (v == null || v.videoWidth == 0) return null;
    // 全解析度取幀：發票 QR 模組細密——1280 縮取樣會把模組壓小 33%
    // ＋JPEG 糊化 → zxing 全解不出（PM 2026-11-21「全部掃描失敗」
    // 回歸根因）。上限 1920 僅防極端 4K 串流。
    final scale = v.videoWidth > 1920 ? 1920 / v.videoWidth : 1.0;
    final w = (v.videoWidth * scale).round();
    final h = (v.videoHeight * scale).round();
    final canvas =
        web.document.createElement('canvas') as web.HTMLCanvasElement
          ..width = w
          ..height = h;
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
    ctx.drawImage(v, 0, 0, w, h);
    final dataUrl = canvas.toDataURL('image/jpeg', 0.8.toJS);
    final b64 = dataUrl.split(',').last;
    return Uint8List.fromList(base64Decode(b64));
  }

  /// **黑畫面看門狗**（PM 2026-11-23：每次進掃描頁重新渲染鏡頭——
  /// 進入後若黑畫面（stream 拿到但沒渲染），每秒採樣 16×16 亮度，
  /// 連續 3 次近黑 → 自動停軌重取 stream（自癒上限 5 次）。
  Timer? _watchdog;
  int _blackStreak = 0;
  int _healCount = 0;
  web.HTMLCanvasElement? _probeCanvas;

  void _startWatchdog(web.HTMLVideoElement video) {
    _watchdog?.cancel();
    _blackStreak = 0;
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) async {
      final v = _video;
      if (v == null || v.videoWidth == 0) return;
      if (v.readyState < 2) {
        _blackStreak++;
      } else {
        final lum = _sampleLuminance(v);
        if (lum < 4) {
          _blackStreak++;
        } else {
          _blackStreak = 0;
          return;
        }
      }
      if (_blackStreak >= 3 && _healCount < 5) {
        _blackStreak = 0;
        _healCount++;
        try {
          for (final t in _stream?.getVideoTracks().toDart ?? const []) {
            t.stop();
          }
          await Future.delayed(const Duration(milliseconds: 600));
          await _openOn(video);
        } catch (_) {}
      }
    });
  }

  /// 採樣影像平均亮度（0~255；16×16 縮樣——web 同源不污染）。
  double _sampleLuminance(web.HTMLVideoElement v) {
    final canvas = _probeCanvas ??=
        (web.document.createElement('canvas') as web.HTMLCanvasElement)
          ..width = 16
          ..height = 16;
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
    ctx.drawImage(v, 0, 0, 16, 16);
    final data = ctx.getImageData(0, 0, 16, 16).data.toDart;
    var sum = 0;
    for (var i = 0; i < data.length; i += 4) {
      sum += (0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2])
          .round();
    }
    return sum / (data.length / 4);
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    web.document.removeEventListener('visibilitychange', _visibilityHandler);
    _visibilityHandler = null;
    // iOS：先分離串流再停止軌跡——退出重進的黑畫面
    // 多為相機 session 未完全釋放。
    _video?.srcObject = null;
    if (_stream != null) {
      for (final t in _stream!.getTracks().toDart) {
        t.stop();
      }
    }
    _stream = null;
    _video = null;
    _lastDisposeAt = DateTime.now();
  }

  /// getUserMedia 錯誤分類（單一訊息無法行動——
  /// 權限被拒／無相機／占用／瀏覽器不支援各有對策）。
  CameraUnavailableException _classify(Object e) {
    final s = e.toString();
    if (s.contains('NotAllowedError') ||
        s.contains('SecurityError') ||
        s.contains('PermissionDenied')) {
      return const CameraUnavailableException(
          '相機權限被拒——請允許相機後按「重試」（iOS：設定 → Safari → 相機 → 允許）');
    }
    if (s.contains('NotFoundError') ||
        s.contains('DevicesNotFoundError') ||
        s.contains('OverconstrainedError')) {
      return const CameraUnavailableException('找不到可用的後鏡頭');
    }
    if (s.contains('NotReadableError') || s.contains('TrackStartError')) {
      return const CameraUnavailableException('相機被其他應用程式占用');
    }
    if (s.contains('TypeError') || s.contains('undefined')) {
      // mediaDevices 為 undefined——非安全上下文或不支援的 webview。
      return const CameraUnavailableException(
          '此瀏覽器不支援相機——請以 Safari／Chrome 直接開啟'
          '（LINE 等 App 內建瀏覽器不支援），並確認為 https');
    }
    return const CameraUnavailableException('相機無法使用（需 https 與 Safari／Chrome）');
  }
}

/// 平台分流工廠（條件匯出提供；**不可**在 camera_stream.dart 本地宣告——
/// 本地宣告會遮蔽條件匯出，DBG-018）。
CameraStreamController createCameraController() => WebCameraStreamController();
