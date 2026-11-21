import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'camera_stream.dart';

/// native：相機即時掃描屬 **SP-2b（mobile_scanner）**——現階段不支援；
/// start 拋 [CameraUnavailableException]，呼叫端回退檔案匯入。
class _NativeCameraController implements CameraStreamController {
  @override
  Future<Widget> start() async =>
      throw const CameraUnavailableException('原生相機整合屬 SP-2b（未接線）');

  @override
  Future<Uint8List?> captureFrame() async => null;

  @override
  Future<void> switchCamera() async =>
      throw const CameraUnavailableException('原生相機整合屬 SP-2b（未接線）');

  @override
  String get diagInfo => '';

  @override
  void dispose() {}
}

CameraStreamController createCameraController() => _NativeCameraController();
