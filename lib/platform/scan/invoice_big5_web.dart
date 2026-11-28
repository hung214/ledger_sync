import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Big5 解碼（web——瀏覽器 TextDecoder 原生支援 'big5'）。
/// 回傳解碼後文字（非 Big5 位元組→可能含替換字元，由呼叫端以 CJK
/// 啟發式驗證）；不支援/例外 → null（呼叫端保留原文字）。
String? decodeBig5(List<int> bytes) {
  try {
    final decoder = web.TextDecoder('big5');
    return decoder.decode(Uint8List.fromList(bytes).toJS);
  } catch (_) {
    return null;
  }
}
