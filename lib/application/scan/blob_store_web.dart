import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'blob_store.dart';

/// web（PWA）：IndexedDB key-value（key=sha256；value=二進位）。
///
/// 內容定址語意同 native：`put` 冪等覆寫；瀏覽器自行保證交易落盤。
/// DB/store 名稱常數與 `db_opener_web.dart` 命名規約一致（ledger_sync_*）。
class IdbBlobStore implements BlobStore {
  IdbBlobStore._();

  static const _dbName = 'ledger_sync_blobs';
  static const _storeName = 'blobs';
  static const _version = 1;

  Future<web.IDBDatabase>? _dbFuture;

  Future<web.IDBDatabase> _openDb() {
    final c = Completer<web.IDBDatabase>();
    final req = web.window.indexedDB.open(_dbName, _version);
    req.onupgradeneeded = ((web.Event _) {
      final db = req.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }).toJS;
    req.onsuccess = ((web.Event _) {
      c.complete(req.result as web.IDBDatabase);
    }).toJS;
    req.onerror = ((web.Event _) {
      c.completeError(StateError('IndexedDB 開啟失敗：$_dbName'));
    }).toJS;
    return c.future;
  }

  Future<web.IDBDatabase> get _db => _dbFuture ??= _openDb();

  web.IDBTransaction _tx(web.IDBDatabase db, String mode) =>
      db.transaction(_storeName.toJS, mode);

  static Future<void> _txDone(web.IDBTransaction tx) {
    final c = Completer<void>();
    tx.oncomplete = ((web.Event _) => c.complete()).toJS;
    tx.onerror = ((web.Event _) =>
            c.completeError(StateError('IndexedDB 交易失敗')))
        .toJS;
    return c.future;
  }

  @override
  Future<void> write(String sha256, Uint8List bytes) async {
    final db = await _db;
    final tx = _tx(db, 'readwrite');
    tx.objectStore(_storeName).put(bytes.toJS, sha256.toJS);
    await _txDone(tx);
  }

  @override
  Future<Uint8List?> read(String sha256) async {
    final db = await _db;
    final tx = _tx(db, 'readonly');
    final req = tx.objectStore(_storeName).get(sha256.toJS);
    final result = await _reqResult(req);
    tx.oncomplete = null; // readonly 於取得結果即完成；不額外等待。
    if (result == null) return null;
    return (result as JSUint8Array).toDart;
  }

  @override
  Future<void> delete(String sha256) async {
    final db = await _db;
    final tx = _tx(db, 'readwrite');
    tx.objectStore(_storeName).delete(sha256.toJS);
    await _txDone(tx);
  }

  @override
  Future<void> deleteAll() async {
    final db = await _db;
    final tx = _tx(db, 'readwrite');
    tx.objectStore(_storeName).clear();
    await _txDone(tx);
  }
}

/// promisify：IDBRequest → Future（onsuccess 取 result／onerror 失敗）。
Future<JSAny?> _reqResult(web.IDBRequest req) {
  final c = Completer<JSAny?>();
  req.onsuccess = ((web.Event _) => c.complete(req.result)).toJS;
  req.onerror = ((web.Event _) =>
          c.completeError(StateError('IndexedDB 請求失敗')))
      .toJS;
  return c.future;
}

/// 平台分流工廠（web 分支；dirPath 於 Web 無意義，接受並忽略）。
BlobStore newBlobStore({String? dirPath}) => IdbBlobStore._();
