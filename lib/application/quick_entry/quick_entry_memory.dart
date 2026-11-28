import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/sqlite/app_database.dart';
import '../providers.dart';

/// 快記「記住上次」記憶（PM 2026-10-24）。
///
/// 以**分類（含子分類）**為單位，記住上次輸入的**金額**與 Sticky 參數
/// （**帳戶、商家**）——再次選到同一分類時自動帶入，方便微調後直接儲存。
/// 日期仍預設「現在」。
///
/// 儲存於 settings（`quick.last.{categoryId}`）＝**本機 UX 記憶**：
/// 不進 oplog、不隨雲端同步（與 `app.theme_mode` 同層級；SDD §5.6）。
class QuickEntryMemory {
  QuickEntryMemory(this._db);

  final AppDatabase _db;

  static String _key(String categoryId) => 'quick.last.$categoryId';

  /// 讀取上次記憶（無紀錄或資料損毀 → null＝優雅降級回 Sticky）。
  ({String amount, String? accountId, String merchant})? load(
    String categoryId,
  ) {
    final raw = _db.getSetting(_key(categoryId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return (
        amount: (m['amount'] as String?) ?? '',
        accountId: m['accountId'] as String?,
        merchant: (m['merchant'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// 寫入上次記憶（金額／帳戶／商家）。
  void remember({
    required String categoryId,
    required String amount,
    String? accountId,
    String? merchant,
  }) {
    _db.setSetting(
      _key(categoryId),
      jsonEncode({
        'amount': amount,
        'accountId': accountId,
        'merchant': merchant ?? '',
      }),
    );
  }
}

final quickEntryMemoryProvider = Provider<QuickEntryMemory>(
  (ref) => QuickEntryMemory(ref.watch(dbProvider)),
);

/// 快記頁「帶入上次值」切換（PM 2026-11-28）：**開**＝選分類按原規則帶入
/// （金額/商家；金額已輸入非 0 → 不帶入）；**關**＝單純操作、完全不帶入。
/// 持久化於 settings `quick.bring_in`（'1'/'0'，預設開＝既有行為）——
/// 本機 UX 偏好，不進 oplog（與 `app.theme_mode` 同層級；SDD §5.6）。
final quickBringInToggleProvider =
    NotifierProvider<QuickBringInToggleNotifier, bool>(
      QuickBringInToggleNotifier.new,
    );

class QuickBringInToggleNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(dbProvider).getSetting('quick.bring_in') != '0';

  void set(bool v) {
    ref.read(dbProvider).setSetting('quick.bring_in', v ? '1' : '0');
    state = v;
  }
}
