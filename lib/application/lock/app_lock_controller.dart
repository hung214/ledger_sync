import '../../core/clock.dart';
import 'pin_hash.dart';
import '../../data/sqlite/app_database.dart';

/// App 鎖判定控制器（SDD §7.2；FR-X1/X5；AC-09）。
///
/// - **門檻判定**：切背景時記錄時刻（[onBackground]）；返回時背景時長
///   ≥ 門檻秒數 → 鎖定需求（時間單一來源 Clock——凍結可測邊界）。
/// - **生物辨識退場**：連續失敗 ≥3 → 本次解鎖僅 PIN（[biometricAllowed]）。
/// - **PIN 重設授權（FR-X5）**：已連雲端＋token 驗證通過 → 允許設新 PIN；
///   未連雲端 → **僅「重置 App」**（無繞過 PIN 保留資料的路徑——設計取捨，
///   controller 不提供任何免憑證解鎖方法——安全設計檢驗見 F08-BE S4）。
///
/// 狀態存 settings：lock.pin_hash（sha256 最小實作——TODO(SP-4) Argon2id）、
/// lock.threshold_sec、lock.biometric。
class AppLockController {
  /// [pin] 未提供 → **不寫入 pin_hash**（裝置從未設定 PIN——
  /// PM 2026-10-23 修復：此前建構子強制寫 hash，與「無 PIN」情境矛盾）。
  AppLockController(this._db, {bool biometricEnabled = true, int thresholdSec = 30}) {
    // **僅在無設定時寫入預設**（PM 2026-11-19：每次啟動都覆寫會把使用者
    // 在設定→安全選的門檻/生物辨識打回 30s/預設）。
    if (_db.getSetting('lock.threshold_sec') == null) {
      _db.setSetting('lock.threshold_sec', '$thresholdSec');
    }
    if (_db.getSetting('lock.biometric') == null) {
      _db.setSetting('lock.biometric', biometricEnabled ? 'true' : 'false');
    }
  }

  /// 建構並同時設定 PIN（F15：Argon2id 為非同步——工廠方法）。
  static Future<AppLockController> create(
    AppDatabase db, {
    required String pin,
    bool biometricEnabled = true,
    int thresholdSec = 30,
  }) async {
    final c = AppLockController(db,
        biometricEnabled: biometricEnabled, thresholdSec: thresholdSec);
    await c.setPin(pin);
    return c;
  }

  final AppDatabase _db;

  /// 背景時刻（切背景記錄；null＝在前台）。
  DateTime? _backgroundAt;

  /// 生物辨識失敗計數（本次解鎖週期）。
  int biometricFailures = 0;

  int get thresholdSec =>
      int.tryParse(_db.getSetting('lock.threshold_sec') ?? '') ?? 30;

  bool get biometricEnabled =>
      (_db.getSetting('lock.biometric') ?? 'true') == 'true';

  /// 設定 PIN（F15/SP-4：**Argon2id 帶鹽**——見 pin_hash.dart）。
  Future<void> setPin(String pin) async =>
      _db.setSetting('lock.pin_hash', await PinHasher.hash(pin));

  /// PIN 驗證。**舊格式（FNV）成功 → 透明遷移**重雜湊為 Argon2id（升級不換 PIN）。
  Future<bool> verifyPin(String pin) async {
    final stored = _db.getSetting('lock.pin_hash');
    if (stored == null) return false;
    if (PinHasher.isLegacy(stored)) {
      if (!PinHasher.legacyVerify(pin, stored)) return false;
      await setPin(pin); // 遷移：同 PIN 升級為 Argon2id
      return true;
    }
    return PinHasher.verify(pin, stored);
  }

  /// 是否已設定 PIN（PM 2026-10-23 修復：從未設定 PIN 時，
  /// 清空資料流程應**跳過** PIN 步驟——否則 null 比對恆 false 鎖死）。
  bool get hasPin => _db.getSetting('lock.pin_hash') != null;

  /// 切至背景（lifecycle 鉤子呼叫）。
  void onBackground() => _backgroundAt = Clock.now();

  /// 返回時判定：背景時長 ≥ 門檻 → 鎖定需求（AC-09 邊界：30s 精準）。
  /// **純查詢**（同背景會話可多次邊界探測——29/30/31s 遞增；背景時刻保留，
  /// 由解鎖成功或重新前景操作重置）。
  bool shouldLockOnResume() {
    if (!hasPin) return false; // 無 PIN → 無鎖可言（否則鎖屏無解鎖手段）
    final bg = _backgroundAt;
    if (bg == null) return false;
    final elapsed = Clock.now().difference(bg).inSeconds;
    return elapsed >= thresholdSec;
  }

  /// 生物辨識是否可用（失敗 <3；FR-X1 退場機制）。
  bool get biometricAllowed => biometricEnabled && biometricFailures < 3;

  /// 生物辨識失敗（+1）。
  void onBiometricFail() => biometricFailures++;

  /// 生物辨識成功（計數歸零——解鎖週期重置）。
  void onBiometricSuccess() => biometricFailures = 0;

  /// PIN 重設授權（FR-X5）：已連雲端（settings sync.account 有值）**且**
  /// 雲端 token 驗證通過 → 允許設新 PIN；否則 false（僅「重置 App」）。
  bool canResetPin({required bool cloudTokenValid}) {
    final account = _db.getSetting('sync.account') ?? '';
    return account.isNotEmpty && cloudTokenValid;
  }
}
