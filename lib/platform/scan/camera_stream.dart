/// 相機串流控制器（F14 PWA 即時掃描；平台分流——分析期恆選 base，編譯期 CFE 分流）。
///
/// - **web**：`getUserMedia`（後鏡頭優先）＋`<video>` 預覽＋canvas 取幀（JPEG）。
/// - **native**：暫不支援（SP-2b mobile_scanner）→ start 拋
///   [CameraUnavailableException]，呼叫端回退檔案匯入。
///
/// 詳見 `lib/data/sqlite/db_opener_stub.dart` 註解（stub 型別必須正確）。
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

export 'camera_stream_stub.dart'
    if (dart.library.io) 'camera_stream_native.dart'
    if (dart.library.js_interop) 'camera_stream_web.dart';

class CameraUnavailableException implements Exception {
  const CameraUnavailableException(this.message);
  final String message;

  @override
  String toString() => 'CameraUnavailableException: $message';
}

abstract interface class CameraStreamController {
  /// 啟動相機（請求權限）→ 成功回傳**預覽 Widget**；失敗拋
  /// [CameraUnavailableException]（拒絕/無相機/非 https）。
  Future<Widget> start();

  /// 擷取目前畫面（JPEG bytes）；無畫面回 null。
  Future<Uint8List?> captureFrame();

  /// 停止串流並釋放。
  void dispose();
}

/// 平台分流工廠。
CameraStreamController createCameraController() =>
    throw UnsupportedError('此平台未支援 CameraStreamController');
