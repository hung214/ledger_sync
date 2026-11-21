import '../../domain/entities/account.dart';

/// 掃描發票預設帳戶（PM 2026-11-22）：**最後一次掃描發票入帳的帳戶**；
/// 無（或已刪除/封存）→ **第一個現金帳戶**；再無 → 第一個帳戶；
/// 沒有帳戶 → null（確認頁手動選）。
///
/// 「最後一次掃描」於確認頁每筆入帳時寫入 settings（[kScanLastAccountKey]）；
/// 同回合多張＝Sticky 沿用（確認清單與快記同款互動，PM 2026-11-22）。
const String kScanLastAccountKey = 'scan.lastAccountId';

/// 依規則解析掃描預設帳戶（純函式——可單測）。
String? resolveScanDefaultAccount(
    List<Account> accounts, String? lastScanAccountId) {
  if (accounts.isEmpty) return null;
  if (lastScanAccountId != null) {
    for (final a in accounts) {
      if (a.id == lastScanAccountId) return a.id;
    }
  }
  for (final a in accounts) {
    if (a.type == AccountType.cash) return a.id;
  }
  return accounts.first.id;
}
