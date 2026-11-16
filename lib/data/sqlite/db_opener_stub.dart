import 'package:sqlite3/common.dart';

/// 後備樁（條件匯出的 base）。
///
/// ⚠ **本檔會被 `dart analyze`／`flutter analyze` 恆選為解析目標**（實測：分析期
/// `dart.library.*` 條件一律為 false，真正編譯時 CFE 才依目標平台分流——
/// `flutter test` 於 VM 選 native、`flutter build web` 選 web）。
/// 因此**型別必須與兩個平台實作完全一致**（勿用 `Never` 回傳型別，否則
/// 呼叫端被誤判 dead code）；執行期僅在「未經 Flutter 工具鏈編譯」時觸發。
CommonDatabase openNative({String? path}) =>
    throw UnsupportedError('此平台未支援開庫（openNative；path：$path）');

Future<CommonDatabase> openAppDatabaseWeb() async =>
    throw UnsupportedError('此平台未支援開庫（openAppDatabaseWeb）');

Future<void> closeWebVfs() async {}

void ensureSqliteOpenable() {}
