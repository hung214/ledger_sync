/// Native 平台 stub：不可用（native 走 `file_selector` 官方 `openFile()`——
/// macOS/Windows 有原生檔案對話框，行為正確）。stub 型別必須與 web 版一致。
library;

import 'package:file_selector/file_selector.dart';

/// 永遠拋錯——呼叫端以 `kIsWeb` 分流，native 不會走到這裡。
Future<XFile?> pickWebFile({String? accept}) async {
  throw UnsupportedError('pickWebFile：web 專用（native 請用 file_selector.openFile）');
}
