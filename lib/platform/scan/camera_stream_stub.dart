import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'camera_stream.dart';

/// base 樁（分析期恆選本檔；型別必須與兩平台實作一致——勿 Never）。
class _StubCameraController implements CameraStreamController {
  @override
  Future<Widget> start() async =>
      throw const CameraUnavailableException('此平台未支援相機串流');

  @override
  Future<Uint8List?> captureFrame() async => null;

  @override
  Future<void> switchCamera() async =>
      throw const CameraUnavailableException('此平台未支援相機串流');

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

CameraStreamController createCameraController() => _StubCameraController();
