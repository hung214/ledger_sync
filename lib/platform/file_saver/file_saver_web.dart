import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// web（PWA）下載：`Blob`＋`<a download>` 程式化點擊 → 瀏覽器下載 CSV。
class FileSaver {
  const FileSaver();

  /// 觸發瀏覽器下載；回傳檔名（web 無路徑概念）。恆不回 null。
  Future<String?> saveCsv(String suggestedName, List<int> bytes) async {
    final blob = web.Blob(
        [Uint8List.fromList(bytes).toJS].toJS,
        web.BlobPropertyBag(type: 'text/csv;charset=utf-8'));
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = suggestedName;
    anchor.click();
    web.URL.revokeObjectURL(url);
    return suggestedName;
  }
}
