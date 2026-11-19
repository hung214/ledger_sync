import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

/// native 存檔：`file_selector` 存檔對話框 → 選路徑 → 寫位元組。
class FileSaver {
  const FileSaver();

  /// 回傳所選**完整路徑**；null＝使用者取消對話框。
  Future<String?> saveCsv(String suggestedName, List<int> bytes) async {
    final location = await getSaveLocation(suggestedName: suggestedName);
    if (location == null) return null;
    final data = Uint8List.fromList(bytes);
    final file = XFile.fromData(data,
        mimeType: 'text/csv', name: suggestedName);
    await file.saveTo(location.path);
    return location.path;
  }
}
