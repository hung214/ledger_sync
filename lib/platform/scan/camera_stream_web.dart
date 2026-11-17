import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'camera_stream.dart';

/// web（PWA）相機控制器：`getUserMedia`（後鏡頭優先）＋`<video>` 預覽＋canvas 取幀。
///
/// - 需 **https**（或 localhost）——瀏覽器權限要求。
/// - 預覽以 `HtmlElementView` 嵌入（`ui_web.platformViewRegistry` 註冊）。
/// - 取幀＝video 畫到 canvas → JPEG bytes（品質 0.8）→ 交 zxing2 解碼。
class WebCameraStreamController implements CameraStreamController {
  web.HTMLVideoElement? _video;
  web.MediaStream? _stream;

  static int _seq = 0;
  late final String _viewType = 'webcam-${_seq++}';

  @override
  Future<Widget> start() async {
    try {
      _stream = await web.window.navigator.mediaDevices
          .getUserMedia(
            web.MediaStreamConstraints(
                video: 'environment'.toJS),
          )
          .toDart;
    } catch (_) {
      throw const CameraUnavailableException('相機無法使用（拒絕/無相機/需 https）');
    }
    final video = (web.document.createElement('video') as web.HTMLVideoElement)
      ..autoplay = true
      ..muted = true
      ..playsInline = true
      ..srcObject = _stream;
    _video = video;
    ui_web.platformViewRegistry.registerViewFactory(
        _viewType, (int viewId) => video);
    return HtmlElementView(viewType: _viewType);
  }

  @override
  Future<Uint8List?> captureFrame() async {
    final v = _video;
    if (v == null || v.videoWidth == 0) return null;
    final canvas =
        web.document.createElement('canvas') as web.HTMLCanvasElement
          ..width = v.videoWidth
          ..height = v.videoHeight;
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
    ctx.drawImage(v, 0, 0);
    final dataUrl = canvas.toDataURL('image/jpeg', 0.8.toJS);
    final b64 = dataUrl.split(',').last;
    return Uint8List.fromList(base64Decode(b64));
  }

  @override
  void dispose() {
    if (_stream != null) {
      for (final t in _stream!.getTracks().toDart) {
        t.stop();
      }
    }
    _stream = null;
    _video = null;
  }
}

CameraStreamController createCameraController() => WebCameraStreamController();
