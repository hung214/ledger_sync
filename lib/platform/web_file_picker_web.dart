/// Web（PWA）實作：`<input type="file">` 元素選檔（dart:html——條件匯出
/// 隔離，native 測試不會編到此檔；同 DBG-018 pending_scan_nav 模式）。
///
/// 流程：建立隱藏 input → 設 accept 過濾 → 程式觸發 click（ Flutter
/// onPressed 的 user gesture 內合法）→ onChange 讀 File → FileReader
/// 轉 bytes → 包成 XFile（帶原始檔名，file.name 供 UI 顯示/副檔名判斷）。
/// 取消（onChange 未觸發）→ completer 永不完成 → **需監聽 cancel**：
/// 現代瀏覽器支援 input 的 'cancel' 事件（iOS 16.4+）；舊瀏覽器 fallback
/// ＝focus 回視窗時檢查 files.length。
library;

import 'dart:async';
import 'dart:typed_data';

// 條件匯出隔離，web 專用實作（與 camera_stream_web 同模式）。
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'package:file_selector/file_selector.dart';

Future<XFile?> pickWebFile({String? accept}) async {
  final completer = Completer<XFile?>();
  final input = html.FileUploadInputElement()
    ..accept = accept ?? ''
    ..style.display = 'none';

  void finish(XFile? result) {
    if (!completer.isCompleted) completer.complete(result);
    input.remove();
  }

  input.onChange.listen((_) {
    final files = input.files;
    if (files != null && files.isNotEmpty) {
      final file = files.first;
      final reader = html.FileReader();
      reader.onLoadEnd.listen((_) {
        final result = reader.result;
        final bytes = result is List<int>
            ? Uint8List.fromList(result)
            : Uint8List(0);
        finish(XFile.fromData(bytes, name: file.name,
            mimeType: file.type.isEmpty ? null : file.type));
      });
      reader.onError.listen((_) => finish(null));
      reader.readAsArrayBuffer(file);
    } else {
      finish(null);
    }
  });

  // iOS 16.4+/現代瀏覽器：使用者按「取消」時觸發 cancel 事件
  // （dart:html 無 onCancel getter——用 addEventListener）。
  input.addEventListener('cancel', (_) => finish(null));

  html.document.body?.append(input);
  input.click();
  return completer.future;
}
