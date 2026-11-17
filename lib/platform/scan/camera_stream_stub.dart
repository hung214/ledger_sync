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
  void dispose() {}
}

CameraStreamController createCameraController() => _StubCameraController();
