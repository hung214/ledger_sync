import 'dart:typed_data';

import 'text_ocr.dart';

/// stub（web/分析期）：不支援——回空清單（呼叫端回退手動開卡）。
class TextOcrServiceImpl implements TextOcrService {
  const TextOcrServiceImpl();

  @override
  bool get isSupported => false;

  @override
  Future<List<String>> recognizeTextLines(Uint8List bytes) async => const [];
}

/// 工廠（條件匯出進入點）。
TextOcrService createTextOcrService() => const TextOcrServiceImpl();
