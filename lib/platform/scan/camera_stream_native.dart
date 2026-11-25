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
  Future<AnalysisFrame?> captureAnalysisFrame() async => null;

  @override
  Future<void> resumePreview() async {}

  @override
  Future<void> switchCamera() async =>
      throw const CameraUnavailableException('原生相機整合屬 SP-2b（未接線）');

  @override
  String get diagInfo => '';
  @override
  String get resolutionInfo => '';

  @override
  bool get hasNativeBarcodeDetector => false;

  @override
  Future<List<DetectedCode>> detectNativeBarcodes() async => const [];

  @override
  bool get torchSupported => false;

  @override
  bool get zoomSupported => false; // native 掃描頁自管 zoom（mobile_scanner 按鈕）。

  @override
  Future<void> setZoom(double normalized) async {}

  @override
  Future<void> toggleTorch() async {}

  @override
  bool get torchOn => false;

  @override
  void dispose() {}
}

CameraStreamController createCameraController() => _NativeCameraController();
