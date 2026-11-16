import 'dart:typed_data';

/// base 樁（分析期恆選本檔；型別必須與兩平台實作一致——勿 Never）。
Future<void> saveBytesToPath(String path, Uint8List bytes) async =>
    throw UnsupportedError('此平台未支援 saveBytesToPath（path：$path）');

Future<Uint8List> readBytesFromPath(String path) async =>
    throw UnsupportedError('此平台未支援 readBytesFromPath（path：$path）');
