import 'dart:js_interop';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:web/web.dart' as web;

/// web（PWA）下載：Blob＋`<a download>`（檔名＝呼叫端傳入之**建議檔名**）。
///
/// 不走 `XFile.fromData().saveTo`——其 href/download 皆空字串
/// （fromData 未帶 name/path）→ 瀏覽器存出**無名無副檔名**的檔案
/// （PM 2026-11-21 實測：PWA 備份檔）。file_selector_web 的
/// `getSaveLocation` 恆回 `FileSaveLocation('')`（官方 dummy——僅為
/// API 相容；web 無存檔對話框），呼叫端於 web 傳**建議檔名**進來。
Future<void> saveBytesToPath(String path, Uint8List bytes) async {
  final suggested = path.isEmpty ? 'download' : _basename(path);
  final blob = web.Blob([Uint8List.fromList(bytes).toJS].toJS);
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = suggested;
  anchor.click();
  web.URL.revokeObjectURL(url);
}

String _basename(String p) {
  final norm = p.replaceAll('\\', '/');
  return norm.substring(norm.lastIndexOf('/') + 1);
}

Future<Uint8List> readBytesFromPath(String path) async =>
    await XFile(path).readAsBytes();
