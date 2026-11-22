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
  Future<void> setFocusPoint(Offset normalized) async {}

  @override
  ({List<Rect> boxes, Size frameSize})? get lastNativeBoxes => null;


  @override
  void dispose() {}
}

CameraStreamController createCameraController() => _NativeCameraController();
