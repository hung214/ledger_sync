import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'text_ocr.dart';

/// io（iOS/macOS）實作：Apple Vision 文字辨識（VNRecognizeTextRequest）——
/// 接既有 mobile_scanner method channel（patch `ledgerSync.recognizeText`；
/// pub upgrade 沖掉 patch → MissingPluginException → 空清單自動回退）。
class TextOcrServiceImpl implements TextOcrService {
  const TextOcrServiceImpl();

  static const MethodChannel _channel =
      MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');

  @override
  bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Future<List<String>> recognizeTextLines(Uint8List bytes) async {
    if (!isSupported) return const [];
    File? tmp;
    try {
      // Vision 支援 JPEG/PNG/HEIC——原樣落地（副檔名僅提示用）。
      tmp = File(
          '${Directory.systemTemp.path}/ls_ocr_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await tmp.writeAsBytes(bytes);
      final r = await _channel.invokeMethod<List<dynamic>>(
          'ledgerSync.recognizeText', {'path': tmp.path});
      return r?.cast<String>() ?? const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    } finally {
      try {
        if (await tmp?.exists() ?? false) await tmp!.delete();
      } catch (_) {
        // 暫存清理失敗不影響結果。
      }
    }
  }
}

/// 工廠（條件匯出進入點）。
TextOcrService createTextOcrService() => const TextOcrServiceImpl();
