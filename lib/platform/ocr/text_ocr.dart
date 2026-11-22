/// 紙本發票 OCR 介面（T12，PM 2026-11-22：紙本**無條碼、只有印刷發票
/// 號碼**）。實作經條件匯出分流：**io（iOS/macOS）**＝Apple Vision 文字
/// 辨識（接既有 mobile_scanner channel patch）；**web/其他**＝stub（空）。
/// 平台能力總表見 scan_policy.dart。
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

export 'text_ocr_stub.dart'
    if (dart.library.io) 'text_ocr_io.dart';

/// OCR 服務介面（呼叫端不感知平台差異；不支援平台回空清單）。
abstract interface class TextOcrService {
  /// 平台可能支援（實際以 channel 呼叫結果為準——patch 被沖掉時
  /// MissingPluginException → 空清單）。
  bool get isSupported;

  /// 對照片做文字辨識 → 文字行清單（不支援/失敗 → 空清單）。
  Future<List<String>> recognizeTextLines(Uint8List bytes);
}

/// 自文字行找出**發票號碼**（2 碼英文＋8 數字；容許連字號/空白——
/// 紙本發票印刷常見「AB-12345678」「AB 12345678」「AB12345678」）。
///
/// **分行配對**（PM 實測 2075/2076：收銀機發票的字軌與號碼**分兩行印**——
/// 「EF」一行、「20947672」一行）：同行直配失敗時，取字軌行最近的
/// 8 位數字行配對（OCR 順序不保證，前後都找）。
String? findInvoiceNo(List<String> lines) {
  final invRe = RegExp(r'([A-Z]{2})\s*[-–]?\s*([0-9]{8})');
  // ① 同行直接命中。
  for (final line in lines) {
    final m = invRe.firstMatch(line.toUpperCase());
    if (m != null) return '${m.group(1)}${m.group(2)}';
  }
  // ② 分行配對：字軌行（恰 2 大寫字母）× 數字行（恰 8 位數字）。
  final upper = [for (final l in lines) l.trim().toUpperCase()];
  final digitIdx = <int>[
    for (var i = 0; i < upper.length; i++)
      if (RegExp(r'^[0-9]{8}$').hasMatch(upper[i])) i,
  ];
  for (var i = 0; i < upper.length; i++) {
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(upper[i])) continue;
    int? best;
    var bestDist = 1 << 30;
    for (final j in digitIdx) {
      final d = (j - i).abs();
      if (d < bestDist) {
        bestDist = d;
        best = j;
      }
    }
    if (best != null) return '${upper[i]}${upper[best]}';
  }
  return null;
}

/// 自文字行找出**印刷日期**（紙本發票「日期20260913」——西元 8 位）。
/// 民國（096/115 開頭 7 位）亦支援。找不到回 null（確認卡預今天）。
DateTime? findPrintedDate(List<String> lines) {
  final adRe = RegExp(
      r'(19[0-9]{2}|20[0-9]{2})\s*[年/.-]?\s*([0-9]{1,2})\s*[月/.-]?\s*([0-9]{1,2})');
  // 民國 096-149（有無前導零皆可）。
  final rocRe = RegExp(
      r'(0[0-9]{2}|1[0-4][0-9])\s*年\s*([0-9]{1,2})\s*月\s*([0-9]{1,2})\s*日');
  DateTime? tryAd(String line) {
    final m = adRe.firstMatch(line);
    if (m == null) return null;
    final d = DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!),
        int.parse(m.group(3)!));
    return (d.year >= 2000 && d.year <= 2100) ? d : null;
  }

  DateTime? tryRoc(String line) {
    final r = rocRe.firstMatch(line);
    if (r == null) return null;
    final d = DateTime(int.parse(r.group(1)!) + 1911, int.parse(r.group(2)!),
        int.parse(r.group(3)!));
    return (d.year >= 2007 && d.year <= 2100) ? d : null;
  }

  // ①「日期」行優先（PM 實測 2075：「日期20260913 時間1234」）。
  for (final line in lines) {
    if (!line.contains('日期')) continue;
    final d = tryAd(line) ?? tryRoc(line);
    if (d != null) return d;
  }
  // ② 其他行（排除「月份/期別」標籤——「115年9-10月份」非交易日期）。
  for (final line in lines) {
    if (line.contains('月份') || line.contains('期別')) continue;
    final d = tryAd(line) ?? tryRoc(line);
    if (d != null) return d;
  }
  return null;
}

/// 便利管線：bytes →（大圖降採樣——Vision 對 12MP 直接處理較慢）→ 文字行。
/// 前處理為純 Dart（image 套件跨平台）；辨識本體走 [TextOcrService]。
Future<List<String>> recognizeInvoiceText(
    TextOcrService service, Uint8List bytes) async {
  if (!service.isSupported) return const [];
  var data = bytes;
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded != null) {
      final maxDim =
          decoded.width > decoded.height ? decoded.width : decoded.height;
      if (maxDim > 2000) {
        final scale = 2000 / maxDim;
        data = Uint8List.fromList(img.encodeJpg(
            img.copyResize(decoded,
                width: (decoded.width * scale).round(),
                height: (decoded.height * scale).round()),
            quality: 90));
      }
    }
  } catch (_) {
    data = bytes; // 解碼失敗——原樣送辨識
  }
  return service.recognizeTextLines(data);
}
