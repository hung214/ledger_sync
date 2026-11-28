import 'dart:convert';

import 'invoice_big5.dart';

/// 發票 QR 文字編碼還原（**T93 繁中亂碼修復**——PM 2026-11-28）。
///
/// 背景：發票 QR 的 Byte-mode 內容**無 ECI 標記**時，偵測器以 ISO-8859-1
/// 預設解碼——中文（UTF-8 或 Big5）變亂碼：
/// - UTF-8 位元組被 Latin-1 逐字元映射 → `å¥½` 形（**可逆**——latin1.encode
///   還原位元組再 utf8 嚴格解碼）
/// - Big5 位元組（7-11 POS）被同樣映射 → `¦nªº` 形（**可逆**——還原位元組
///   後 Big5 解碼，web＝TextDecoder('big5')）
/// - 偵測器內部已嘗試 UTF-8 → U+FFFD 替換（**不可逆於文字層**——需
///   rawBytes；web 原生偵測器不提供位元組＝此形在原生路徑無法還原，
///   改由 zxing2 重解該區域取得位元組）
///
/// 判定：文字含 U+FFFD 或 **Latin-1 高區字元（0x80~0xFF）**＝可疑
/// （正常發票內容＝ASCII＋CJK，不含 0x80~0xFF）。
bool isSuspectMojibake(String text) {
  if (text.contains('\uFFFD')) return true;
  for (final c in text.codeUnits) {
    if (c >= 0x80 && c <= 0xFF) return true;
  }
  return false;
}

bool _hasCJK(String s) {
  for (final c in s.codeUnits) {
    if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF)) {
      return true;
    }
  }
  return false;
}

/// 還原發票 QR 文字。非可疑 → 原樣；無法還原 → 原樣（優雅降級）。
/// [rawBytes]＝偵測器提供的原始位元組（zxing2 Result.rawBytes；有則優先——
/// 可救 U+FFFD 形）。[isBig5Hint]＝呼叫端判定該碼為 Big5 通路（7-11 等）。
String recoverInvoiceText(
  String text, {
  List<int>? rawBytes,
  bool isBig5Hint = false,
}) {
  if (!isSuspectMojibake(text)) return text;
  // 候選位元組：rawBytes 優先；Latin-1 全字元 ≤0xFF → latin1.encode 還原。
  List<int>? bytes = rawBytes;
  bytes ??= text.codeUnits.every((c) => c <= 0xFF) ? text.codeUnits : null;
  if (bytes == null || bytes.isEmpty) return text;
  // ①UTF-8 嚴格解碼（官方規格）——成功且含 CJK → 採用。
  try {
    final u = utf8.decode(bytes, allowMalformed: false);
    if (_hasCJK(u) && !u.contains('\uFFFD')) return u;
  } catch (_) {}
  // ②Big5 解碼（web TextDecoder；7-11 等通路）——成功且含 CJK → 採用。
  final b = decodeBig5(bytes);
  if (b != null && _hasCJK(b) && !b.contains('\uFFFD')) return b;
  // ③仍無法還原：Latin-1 高區字元（Big5 誤映射特徵）→ 至少標記。
  return text;
}
