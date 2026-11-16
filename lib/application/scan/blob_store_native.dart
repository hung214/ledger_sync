import 'dart:io';
import 'dart:typed_data';

import 'blob_store.dart';

/// native（Android／iOS／macOS／Windows）：檔案系統 `blobs/{sha256}`。
/// 行為與 v0.4.x 完全一致（原 AttachmentStore 內嵌邏輯抽出）。
class FileBlobStore implements BlobStore {
  FileBlobStore(this.dirPath);

  /// blobs 目錄（app 支援目錄下；測試注入暫存目錄）。
  final String dirPath;

  File _fileOf(String sha256) => File('$dirPath/$sha256');

  @override
  Future<void> write(String sha256, Uint8List bytes) async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    await _fileOf(sha256).writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List?> read(String sha256) async {
    final f = _fileOf(sha256);
    if (!f.existsSync()) return null;
    return f.readAsBytesSync();
  }

  @override
  Future<void> delete(String sha256) async {
    final f = _fileOf(sha256);
    if (f.existsSync()) await f.delete();
  }

  @override
  Future<void> deleteAll() async {
    final dir = Directory(dirPath);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}

/// 平台分流工廠（native 分支）。
BlobStore newBlobStore({String? dirPath}) => FileBlobStore(dirPath!);
