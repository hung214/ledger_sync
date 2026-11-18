import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/lock/app_lock_controller.dart';
import 'package:ledger_sync/application/lock/pin_hash.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';

/// F15／SP-4：PIN 雜湊 FNV-1a 32bit（弱）→ **Argon2id 帶鹽**。
///
/// 驗收：①新格式（前綴+鹽）②正確/錯誤 PIN ③**同 PIN 兩次雜湊不同（鹽唯一）**
/// ④**舊格式透明遷移**（verify 成功即升級，同 PIN 不變）⑤常數時間比較。
void main() {
  test('hash：新格式（v2.argon2id 前綴＋鹽＋雜湊）', () async {
    final stored = await PinHasher.hash('1234');
    expect(stored.startsWith('v2.argon2id\$'), isTrue);
    expect(stored.split('\$').length, 3);
    expect(await PinHasher.verify('1234', stored), isTrue);
    expect(await PinHasher.verify('4321', stored), isFalse, reason: '錯誤 PIN');
  });

  test('鹽唯一性：同 PIN 兩次雜湊→儲存值不同但皆可驗證', () async {
    final a = await PinHasher.hash('1234');
    final b = await PinHasher.hash('1234');
    expect(a, isNot(b), reason: '鹽隨機 → 儲存值不同');
    expect(await PinHasher.verify('1234', a), isTrue);
    expect(await PinHasher.verify('1234', b), isTrue);
  });

  test('舊格式（FNV）：可驗證＋isLegacy 偵測', () {
    final legacy = PinHasher.legacyFnvHash('1234');
    expect(PinHasher.isLegacy(legacy), isTrue, reason: '無 v2 前綴＝舊格式');
    expect(PinHasher.legacyVerify('1234', legacy), isTrue);
    expect(PinHasher.legacyVerify('4321', legacy), isFalse);
  });

  test('controller 透明遷移：舊格式驗證成功 → 自動升級為 Argon2id', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final legacy = PinHasher.legacyFnvHash('1234');
    db.setSetting('lock.pin_hash', legacy); // 模擬舊版裝置
    final controller = AppLockController(db, thresholdSec: 30);

    expect(await controller.verifyPin('1234'), isTrue, reason: '舊 PIN 仍可解鎖');
    final migrated = db.getSetting('lock.pin_hash')!;
    expect(migrated.startsWith('v2.argon2id\$'), isTrue, reason: '已遷移為 Argon2id');
    expect(migrated, isNot(legacy));
    // 遷移後：新格式驗證、舊 PIN 不變
    expect(await controller.verifyPin('1234'), isTrue);
    expect(await controller.verifyPin('9999'), isFalse);
  });

  test('controller：hasPin／未設定 PIN 驗證回 false', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final controller = AppLockController(db, thresholdSec: 30);
    expect(controller.hasPin, isFalse);
    expect(await controller.verifyPin('1234'), isFalse, reason: '未設定 PIN');
    await controller.setPin('5678');
    expect(controller.hasPin, isTrue);
    expect(await controller.verifyPin('5678'), isTrue);
  });

  test('constTimeEquals：等長/不等長/逐位', () {
    expect(PinHasher.constTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
    expect(PinHasher.constTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
    expect(PinHasher.constTimeEquals([1, 2], [1, 2, 3]), isFalse);
  });
}
