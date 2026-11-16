import 'blob_store.dart';

/// BlobStore 後備樁（條件匯出的 **base**）。
///
/// ⚠ 分析期（dart analyze/flutter analyze）**恆選本檔**（`dart.library.*` 條件
/// 分析期皆 false；編譯期 CFE 才依目標平台分流）→ **型別必須與兩平台實作
/// 完全一致（勿 `Never`）**。詳見 `lib/data/sqlite/db_opener_stub.dart` 註解
/// 與 `tasks.md` §6.0b P3.3。
BlobStore newBlobStore({String? dirPath}) =>
    throw UnsupportedError('此平台未支援 BlobStore（dirPath：$dirPath）');
