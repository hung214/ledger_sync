import 'dart:async';

/// stub＝型別基準（Dart 3.13 分析期恆選 base 檔；型別必須正確——勿 Never）。
/// 僅在未接線環境被呼叫——正常程式以 provider override 注入平台實作。
class FileSaver {
  const FileSaver();

  /// 存檔／下載 CSV。回傳目的地描述（路徑或檔名）；null＝使用者取消。
  /// [bytes] 為 UTF-8＋BOM 編碼後的內容（由呼叫端備妥）。
  Future<String?> saveCsv(String suggestedName, List<int> bytes) async =>
      throw UnimplementedError('fileSaverProvider 須於 main()/測試 override 注入');
}
