import 'dart:io';
import 'dart:typed_data';

/// native（macOS/Windows/Android/iOS）：寫入／讀取所選路徑（同步——widget 測試可測；檔案小）。
Future<void> saveBytesToPath(String path, Uint8List bytes) async {
  File(path).writeAsBytesSync(bytes, flush: true);
}

Future<Uint8List> readBytesFromPath(String path) async =>
    File(path).readAsBytesSync();
