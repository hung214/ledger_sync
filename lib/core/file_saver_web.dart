import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

/// web（PWA）：`XFile.saveTo` 忽略 path、觸發瀏覽器**下載**
/// （file_selector_web getSaveLocation 回 dummy path——官方設計）；
/// 讀取＝`XFile.readAsBytes`（瀏覽器提供內容）。
Future<void> saveBytesToPath(String path, Uint8List bytes) async {
  await XFile.fromData(bytes, mimeType: 'application/octet-stream')
      .saveTo(path);
}

Future<Uint8List> readBytesFromPath(String path) async =>
    await XFile(path).readAsBytes();
