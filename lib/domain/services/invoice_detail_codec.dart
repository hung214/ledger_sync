import 'dart:convert';

// P6 Web（PWA）：v4 公開 API 未暴露 raw deflate；直接取其核心 Deflate/Inflate
// （**純 Dart**，跨平台位元組一致——平台加速僅用於 gzip/zlib 外殼，核心不受影響）。
// 規格＝財政部 raw deflate＋Base32。
// ignore: implementation_imports
import 'package:archive/src/codecs/zlib/deflate.dart';
// ignore: implementation_imports
import 'package:archive/src/codecs/zlib/inflate.dart';

/// 台灣電子發票右側 QR 明細編碼（SDD §5.4）：**deflate（raw）＋ Base32（字元集 0-9A-Z）**。
///
/// 規格由財政部訂定；本編碼器同時用於測資產生（T-H6 fixtures）與解析回程，
/// 規格變動 → 版本化調整並以金測樣本回歸（SDD R6）。
class InvoiceDetailCodec {
  InvoiceDetailCodec._();

  static const String _alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

  static String encode(String text) =>
      base32Encode(Deflate(utf8.encode(text)).getBytes());

  static String decode(String encoded) =>
      utf8.decode(Inflate(base32Decode(encoded)).getBytes());

  /// Base32（0-9A-Z，無 padding）：5 bits 一組，尾端補零湊滿。
  static String base32Encode(List<int> bytes) {
    var buffer = 0;
    var bits = 0;
    final out = StringBuffer();
    for (final b in bytes) {
      buffer = (buffer << 8) | (b & 0xFF);
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.write(_alphabet[(buffer >> bits) & 0x1F]);
      }
    }
    if (bits > 0) {
      out.write(_alphabet[(buffer << (5 - bits)) & 0x1F]);
    }
    return out.toString();
  }

  static List<int> base32Decode(String s) {
    final clean = s.replaceAll('=', '');
    var buffer = 0;
    var bits = 0;
    final out = <int>[];
    for (final ch in clean.runes) {
      final v = _alphabet.indexOf(String.fromCharCode(ch));
      if (v < 0) {
        throw FormatException('Base32 字元集外: ${String.fromCharCode(ch)}');
      }
      buffer = (buffer << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xFF);
      }
    }
    return out;
  }
}
