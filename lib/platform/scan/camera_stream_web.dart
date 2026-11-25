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
  external JSObject? get boundingBox; // DOMRectReadOnly（video 像素座標）。
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
  // **zoom 能力**（T82——getUserMedia capabilities 探測；iOS Safari 對
  // zoom constraint 支援有限——不支援＝只顯示距離引導文案）。
  bool _zoomSupported = false;
  double _zoomMin = 1.0;
  double _zoomMax = 3.0;

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
  Future<List<DetectedCode>> detectNativeBarcodes() async {
    final v = _video;
    final detector = _getNativeDetector();
    if (v == null || v.videoWidth == 0 || detector == null) return const [];
    try {
      final results = await detector.detect(v).toDart;
      return [
        for (final r in results.toDart)
          if ((r.rawValue?.toDart ?? '').isNotEmpty)
            DetectedCode(
              text: r.rawValue!.toDart,
              box: _rectFromDomRect(r.boundingBox),
            ),
      ];
    } catch (_) {
      return const []; // 偵測失敗——退回 zxing2 後備（呼叫端分流）。
    }
  }

  /// DOMRectReadOnly（video 像素座標）→ dart:ui Rect（T88 偵測框）。
  static Rect? _rectFromDomRect(JSObject? box) {
    if (box == null) return null;
    try {
      final d = box.dartify() as Map<Object?, Object?>;
      final x = (d['x'] as num?)?.toDouble();
      final y = (d['y'] as num?)?.toDouble();
      final w = (d['width'] as num?)?.toDouble();
      final h = (d['height'] as num?)?.toDouble();
      if (x == null || y == null || w == null || h == null) return null;
      return Rect.fromLTWH(x, y, w, h);
    } catch (_) {
      return null;
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

  @override
  bool get zoomSupported => _zoomSupported;

  /// zoom 能力探測（相機啟動後呼叫——capabilities.zoom 有 min/max 才支援）。
  ///
  /// 動態探測（dart2js 的 dynamic 調用直讀 JS 屬性——capabilities.zoom 是
  /// 可選成員，硬體不支援時＝undefined → dynamic 讀為 null）。
  void probeZoomCapabilities(web.MediaStreamTrack track) {
    try {
      final dynamic zoom = (track.getCapabilities() as dynamic).zoom;
      if (zoom == null) {
        _zoomSupported = false;
        return;
      }
      _zoomMin = (zoom.min as num).toDouble();
      _zoomMax = (zoom.max as num).toDouble();
      _zoomSupported = _zoomMax > _zoomMin;
    } catch (_) {
      _zoomSupported = false; // 不支援（iOS Safari 常見）——只顯示距離引導。
    }
  }

  @override
  Future<void> setZoom(double normalized) async {
    if (!_zoomSupported) return;
    final track = _videoTracks().firstOrNull;
    if (track == null) return;
    final target =
        _zoomMin + (_zoomMax - _zoomMin) * normalized.clamp(0.0, 1.0);
    try {
      final advanced = <web.MediaTrackConstraintSet>[
        web.MediaTrackConstraintSet(zoom: target.toJS),
      ].toJS;
      await track
          .applyConstraints(web.MediaTrackConstraints(advanced: advanced))
          .toDart;
    } catch (_) {
      // 硬體拒絕（正值域外等）——靜默。
    }
  }

  static DateTime? _lastDisposeAt; // 跨實例：退出重進的釋放等待基準

  // === iOS PWA 相機策略（PM 2026-11-23 實測迭代結論）：
  // session 內「已啟動」相機一旦停軌＝管線毒化，之後所有 getUserMedia
  // 皆黑（只有 process 首次啟動可用；強制關閉 PWA 才恢復）。全程保活
  // （20261124u）雖讓重進有畫面，但相機燈離開掃描頁仍亮（PM：不對）。
  // **最終策略：離開即關燈＋標記；重進偵測標記 → 整頁重載**（乾淨
  // JS context＝第一次啟動行為，PM 已驗證可靠）＋重載後自動回掃描頁。 ===
  static web.HTMLVideoElement? _sharedVideo; // session 唯一 video 元素
  static bool _factoryRegistered = false;
  static const String _sharedViewType = 'webcam-shared';

  /// sessionStorage keys：離開掃描頁停了活相機 → 重進需整頁重載；
  /// 重載完成 → 自動回掃描頁。
  static const String _kReopenFlag = 'ls_scan_reopen';
  static const String _kPendingScan = 'ls_pending_scan';
  static const String _kHealReloadCount = 'ls_heal_reload_count';

  @override
  Future<Widget> start() async {
    // 上次離開掃描頁停了活相機（管線已毒化）→ 整頁重載取乾淨 context。
    try {
      final reopen = web.window.sessionStorage.getItem(_kReopenFlag);
      if (reopen != null) {
        web.window.sessionStorage.removeItem(_kReopenFlag);
        web.window.sessionStorage.setItem(_kPendingScan, '1');
        web.window.location.reload();
        // 頁面即將卸載——回傳佔位（不會被渲染到）。
        return HtmlElementView(viewType: _sharedViewType);
      }
    } catch (_) {/* sessionStorage 不可用——照原流程 */}
    // video 元素：整個 session 只建立一次。
    // **T87 尺寸修復**（PM 2026-11-25「鏡頭畫面變小；第二次掃描又更小」）：
    // video 無 CSS 時以**原生解析度**渲染（1920×1080 在預覽槽內＝放大
    // 裁切，且每次重取相機談判解析度不同→每次進頁觀感都變）。固定
    // 100%×100%＋object-fit:cover＝相機 App 標準填滿行為——解析度變動
    // 不再影響畫面觀感（解碼用全幀，與顯示裁切無關——辨識不受影響）。
    _sharedVideo ??=
        (web.document.createElement('video') as web.HTMLVideoElement)
          ..autoplay = true
          ..muted = true
          ..playsInline = true
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.setProperty('object-fit', 'cover')
          ..style.setProperty('object-position', 'center');
    if (!_factoryRegistered) {
      ui_web.platformViewRegistry.registerViewFactory(
          _sharedViewType, (int viewId) => _sharedVideo!);
      _factoryRegistered = true;
    }
    final video = _sharedVideo!;
    _video = video;
    try {
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
    return HtmlElementView(viewType: _sharedViewType);
  }

  /// 完整開機流程：取得後鏡頭串流 → 掛到 video → play。
  /// 開機世代（重進/切鏡頭/看門狗重取會遞增——舊驗證迴圈自動失效）。
  int _openGen = 0;

  Future<void> _openOn(web.HTMLVideoElement video) async {
    final gen = ++_openGen;
    _stopStreamTracks(); // 確保無殘留軌道（硬體鎖釋放後再取）
    _stream = await _acquireRearCamera();
    // zoom 能力探測（T82）——capabilities.zoom 存在才支援變焦。
    final firstTrack = _videoTracks().firstOrNull;
    if (firstTrack != null) probeZoomCapabilities(firstTrack);
    video.srcObject = _stream;
    // 初始/恢復一律後鏡頭——鏡像清除（防切換失敗殘留 scaleX(-1)，
    // PM 2026-11-21「顯示不正常」＝鏡像殘留疊在後鏡頭上）。
    video.style.setProperty('transform', 'none');
    _assertPreviewCss(video);
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
          if (_sampleLuminance(video) > 4) {
            // 幀流動 ✓——清癒後重載計數。
            try {
              web.window.sessionStorage.removeItem(_kHealReloadCount);
            } catch (_) {}
            return;
          }
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
    // 4 輪自癒全數失敗 → **整頁重載後備**（乾淨 context＝第一次啟動行為；
    // 上限 2 次避免硬體故障時無限重載迴圈）。
    try {
      final prev =
          int.tryParse(web.window.sessionStorage.getItem(_kHealReloadCount) ??
                  '0') ??
              0;
      if (prev < 2) {
        web.window.sessionStorage.setItem(_kHealReloadCount, '${prev + 1}');
        web.window.sessionStorage.setItem(_kPendingScan, '1');
        web.window.location.reload();
      }
    } catch (_) {}
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
          // **T86 根因修復（紅米 Note 11 Pro 5G 辨識不到）**：deviceId 精選
          // 重取**必須帶 hiRes 約束**——原寫法只給 deviceId＝裝置**預設檔
          // （Android Chrome 常 640×480）**，QR 模組過小無法辨識。PM 實測
          // 「切換鏡頭再切回來就變好」＝switchCamera 路徑走
          // _tryGetUserMedia（有 hiRes）→ 解析度升級——與此根因吻合。
          stream = await md.getUserMedia(web.MediaStreamConstraints(
              video: {
            'deviceId': {'exact': rearId},
            'width': {'ideal': 1920, 'max': 1920},
            'height': {'ideal': 1080, 'max': 1080},
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
    // **T87**：加 **max 上限**——ideal 允許更高（4K 裝置會給 3840×2160：
    // 截幀 JPEG→base64 每 tick 拖慢解碼＋顯示觀感跳動）；上限不會
    // OverconstrainedError（裝置 max 較低時照給）。
    final hiRes = {
      'width': {'ideal': 1920, 'max': 1920},
      'height': {'ideal': 1080, 'max': 1080},
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
      for (final t in _videoTracks()) {
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
      _assertPreviewCss(video);
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

  /// 目前串流的視訊軌（**型別正確**——不可用 `?? const []`：空字面量
  /// 無上下文推斷成 `List<dynamic>`，LUB 降級迴圈變數為 dynamic →
  /// interop 呼叫變動態派發 → raw JS 軌道缺 Dart selector →
  /// NoSuchMethodError 'stop'（PM 實機 2026-11-23）。
  List<web.MediaStreamTrack> _videoTracks() {
    final stream = _stream;
    if (stream == null) return const <web.MediaStreamTrack>[];
    return stream.getVideoTracks().toDart;
  }

  /// 停止目前串流所有軌道（釋放相機硬體鎖）。
  void _stopStreamTracks() {
    for (final t in _videoTracks()) {
      t.stop();
    }
  }

  @override
  Future<Uint8List?> captureFrame() async {
    final v = _video;
    // **T86**：readyState<2（幀未就緒）時 drawImage/toDataURL 可能擲例外
    // ——呼叫端 tick 死鎖防護（配合頁面 try/finally 雙保險）。
    if (v == null || v.videoWidth == 0 || v.readyState < 2) return null;
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
    // **T89**：本函式現在**只在入單時擷一次**（照片附件）——每 tick 的
    // 解碼已改走 captureAnalysisFrame（RGBA 直入，零編解碼）。同步
    // toDataURL 的 100–300ms 從「每 tick」變「每張發票一次」＝可接受，
    // 並保留 T86 readyState 防護（toDataURL toBlob callback API 差異多，
    // 收益已不需要——維持簡單）。
    final dataUrl = canvas.toDataURL('image/jpeg', 0.8.toJS);
    final b64 = dataUrl.split(',').last;
    return Uint8List.fromList(base64Decode(b64));
  }

  web.HTMLCanvasElement? _analysisCanvas; // 重用（免每 tick 建 canvas）

  static bool? _isIOSCache;
  bool get _isIOS {
    if (_isIOSCache != null) return _isIOSCache!;
    try {
      final ua = web.window.navigator.userAgent.toLowerCase();
      return _isIOSCache =
          ua.contains('iphone') || ua.contains('ipad') || ua.contains('ipod');
    } catch (_) {
      return _isIOSCache = false;
    }
  }

  int _previewGen = 0; // T89c：iOS 返回完全重建世代（viewType 後綴）

  @override
  Future<Widget?> restartPreviewFresh() async {
    if (!_isIOS) return null; // 非 iOS——維持 epoch＋resume 輕量路徑。
    // **T89c**（PM：iPhone 掃一張返回後預覽又變小——Android/桌面已好）：
    // WebKit 對「重掛的 video/slot」殘留轉場/尺寸狀態，同元素重掛治不了
    // → **完全重建**：新 video 元素（含 CSS）＋新串流＋新 viewType slot
    // ＝「第一次啟動行為」（整頁重載同款，PM 已驗證可靠）。
    _watchdog?.cancel();
    try {
      web.document.removeEventListener('visibilitychange', _visibilityHandler);
      _visibilityHandler = null;
    } catch (_) {}
    final gen = ++_previewGen;
    final vt = '$_sharedViewType-$gen';
    final video = (web.document.createElement('video') as web.HTMLVideoElement)
      ..autoplay = true
      ..muted = true
      ..playsInline = true;
    _assertPreviewCss(video);
    _sharedVideo = video;
    _video = video;
    ui_web.platformViewRegistry
        .registerViewFactory(vt, (int viewId) => _sharedVideo!);
    try {
      // 確認清單期間掃描頁仍持有相機：優先將活串流接到新 video，避免
      // 停軌、等待硬體釋放、重新 getUserMedia（iPhone 上約需一秒）。
      final stream = _stream;
      if (stream != null && stream.active) {
        video.srcObject = stream;
        _assertPreviewCss(video);
        try {
          await video.play().toDart;
        } catch (_) {}
        if (video.videoWidth == 0) await _openOn(video);
      } else {
        await _openOn(video);
      }
    } catch (_) {
      return null; // 重取失敗——不換 widget（舊畫面維持，看門狗自癒）。
    }
    _attachVisibilityRevival(video);
    _healCount = 0;
    _startWatchdog(video);
    return HtmlElementView(viewType: vt);
  }

  @override
  Future<void> resumePreview() async {
    final v = _video;
    if (v == null) return;
    _assertPreviewCss(v);
    // 行動版瀏覽器：video 被重掛（確認清單返回的 platform view 重建）
    // 後播放管線可能中斷＝黑畫面（PM 2026-11-25「辨識完回來鏡頭消失，
    // 要切換鏡頭才會顯示」）——重綁串流（null→回）＋補 play＝與切換
    // 鏡頭同原理但**不重新談判相機**（快、無硬體抖動）。串流已死才
    // 走完整重取（黑畫面自癒同款）。
    final s = _stream;
    if (s != null && s.active) {
      try {
        v.srcObject = null;
        v.srcObject = s;
        try {
          await v.play().toDart;
        } catch (_) {}
        return;
      } catch (_) {/* 落到完整重取 */}
    }
    try {
      await _openOn(v);
    } catch (_) {}
  }

  @override
  Future<AnalysisFrame?> captureAnalysisFrame() async {
    final v = _video;
    if (v == null || v.videoWidth == 0 || v.readyState < 2) return null;
    // 上限同 captureFrame（1920 防 4K）；drawImage＋getImageData 皆遠比
    // JPEG 編解碼便宜（getImageData 1280×720 約 5–20ms）。
    final scale = v.videoWidth > 1920 ? 1920 / v.videoWidth : 1.0;
    final w = (v.videoWidth * scale).round();
    final h = (v.videoHeight * scale).round();
    final canvas = _analysisCanvas ??=
        web.document.createElement('canvas') as web.HTMLCanvasElement;
    if (canvas.width != w || canvas.height != h) {
      canvas.width = w;
      canvas.height = h;
    }
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
    ctx.drawImage(v, 0, 0, w, h);
    final data = ctx.getImageData(0, 0, w, h);
    final clamped = data.data.toDart; // Uint8ClampedList
    return AnalysisFrame(
        rgba: Uint8List.sublistView(clamped), width: w, height: h);
  }

  /// **T89**：重斷言預覽 CSS（冪等）——重掛／切換／自癒後一律維持
  /// 100%×100%＋cover（行動版瀏覽器 slot 重建時樣式可能失效；
  /// PM 2026-11-25「返回掃描頁畫面變小」防禦）。
  static void _assertPreviewCss(web.HTMLVideoElement video) {
    video.style.width = '100%';
    video.style.height = '100%';
    video.style.setProperty('object-fit', 'cover');
    video.style.setProperty('object-position', 'center');
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
      _assertPreviewCss(v); // 每秒重斷言（任何路徑掉樣式 1 秒內自癒）
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
          for (final t in _videoTracks()) {
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
    // **離開即關燈**（PM 2026-11-23：相機燈亮著不對）——停軌＋清 srcObject。
    // 停了活相機＝管線毒化 → 標記「重進需整頁重載」（乾淨 context＝
    // 第一次啟動行為，PM 已驗證可靠）。
    var wasLive = false;
    try {
      final tracks = _videoTracks();
      wasLive =
          tracks.isNotEmpty && tracks.any((t) => t.readyState == 'live');
    } catch (_) {}
    _video?.srcObject = null;
    for (final t in _videoTracks()) {
      t.stop();
    }
    if (wasLive) {
      try {
        web.window.sessionStorage.setItem(_kReopenFlag, '1');
      } catch (_) {}
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
