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
  double? get videoAspect => null;

  @override
  String get elementInfo => '';

  @override
  bool get hasNativeBarcodeDetector => false;

  @override
  Future<List<String>> detectNativeBarcodes() async => const [];

  @override
  Duration get decodeInterval => const Duration(milliseconds: 1200);

  @override
  bool get zoomSupported => false;

  @override
  Future<void> setZoom(double normalized) async {}

  @override
  ({List<Rect> boxes, Size frameSize})? get lastNativeBoxes => null;

  @override
  void dispose() {}
}

CameraStreamController createCameraController() => _StubCameraController();
