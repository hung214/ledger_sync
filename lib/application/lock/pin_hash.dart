import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// PIN 雜湊（F15／SP-4：FNV-1a 32bit（弱）→ **Argon2id 帶鹽**，truth D8）。
///
/// 儲存格式（settings `lock.pin_hash`）：
/// - **新**：`v2.argon2id$<saltB64>$<hashB64>`（鹽 16B、雜湊 32B、8MB/parallelism2/1迭代——
///   實測本機 106ms；手機約 2~3 倍，解鎖可接受）
/// - **舊**：FNV-1a 32bit hex（歷史格式）——`verify` 對舊格式成功即回 true，
///   呼叫端（AppLockController.verifyPin）**透明遷移**重雜湊升級。
class PinHasher {
  PinHasher._();

  static const String _prefix = 'v2.argon2id';
  static const int _saltBytes = 16;

  static final Argon2id _algo = Argon2id(
    memory: 8 * 1024, // 8 MiB
    parallelism: 2,
    iterations: 1,
    hashLength: 32,
  );

  /// 產生新格式雜湊。
  static Future<String> hash(String pin) async {
    final salt = Uint8List.fromList(
        List<int>.generate(_saltBytes, (_) => _random.nextInt(256)));
    final out = await _algo.deriveKeyFromPassword(
        password: pin, nonce: salt);
    return '$_prefix\$${base64Encode(salt)}\$${base64Encode(await out.extractBytes())}';
  }

  /// 是否為**舊格式**（FNV hex）。
  static bool isLegacy(String stored) => !stored.startsWith('$_prefix\$');

  /// 舊格式驗證（FNV-1a 32bit；歷史實作搬入——僅供遷移比對）。
  static bool legacyVerify(String pin, String stored) =>
      legacyFnvHash(pin) == stored;

  /// 驗證（自動分派新/舊格式）。
  static Future<bool> verify(String pin, String stored) async {
    if (isLegacy(stored)) return legacyVerify(pin, stored);
    final parts = stored.split('\$');
    if (parts.length != 3) return false;
    final Uint8List salt;
    try {
      salt = base64Decode(parts[1]);
    } on FormatException {
      return false;
    }
    final out = await _algo.deriveKeyFromPassword(password: pin, nonce: salt);
    return constTimeEquals(await out.extractBytes(), base64Decode(parts[2]));
  }

  /// 常數時間比較（避免逐字早退洩漏）。
  static bool constTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static final Random _random = Random.secure();

  /// 舊格式（FNV-1a 32bit）——歷史相容用。
  static String legacyFnvHash(String pin) {
    var h = 0x811c9dc5;
    for (final c in pin.codeUnits) {
      h ^= c & 0xFF;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }
}
