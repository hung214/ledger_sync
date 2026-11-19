import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/file_saver/file_saver.dart';

import '../core/clock.dart';
import '../data/sqlite/app_database.dart';
import 'budgets/budget_alert_service.dart';
import 'credit_card/repay_statement_use_case.dart';
export 'mappers.dart';
import 'notifications/notification_service.dart';
import 'quick_entry/quick_entry_preset_service.dart';
import 'quick_entry/save_transaction_use_case.dart';
import 'quick_entry/undo_last_transaction_use_case.dart';
import 'sync/auto_sync_service.dart';
import 'sync/sync_coordinator.dart';
import 'transactions/delete_transaction_use_case.dart';
import 'transactions/purge_tombstone_use_case.dart';
import 'transactions/restore_transaction_use_case.dart';

/// App 資料庫（M1）。
///
/// **注入約定**：production 由 `main()` 以檔案 DB override（path_provider 決策
/// 待 PM，見 session.md 阻塞清單）；測試以 in-memory DB override（dsl.md §1.5：
/// Given 直寫 fixture，不經 UI）。
final dbProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('dbProvider 須於 main() 或測試 override 注入');
});

/// 快記智慧預設（FR-Q4）。
final quickEntryPresetProvider =
    Provider((ref) => QuickEntryPresetService(ref.watch(dbProvider)));

/// 同步協調器（FR-Y4/Y5；M5）——生產由 main() 以 GoogleDriveAdapter＋
/// 裝置 id override（同 dbProvider 注入約定）；測試以 InMemoryCloudAdapter override。
final syncCoordinatorProvider = Provider<SyncCoordinator>((ref) {
  throw UnimplementedError('syncCoordinatorProvider 須於 main() 或測試 override 注入');
});

/// 自動同步觸發（FR-Y11）——afterSave 依 sync.mode 分流（每筆自動→立即
/// sync；節能批次（預設）→生產 timer；僅手動→設定頁）。mode 未設定時為
/// 節能批次——不觸發 coordinator（override 缺席安全）。
final autoSyncProvider = Provider(
    (ref) => AutoSyncService(ref.watch(dbProvider), ref.watch(syncCoordinatorProvider)));

/// 儲存事務（FR-Q5，SDD §5.1）——入庫後冪等同步預算警示（FR-B4 sync 點①）
/// ＋自動同步觸發（FR-Y11 sync 點②；批次/手動模式下為 no-op）。
final saveTransactionProvider = Provider((ref) => SaveTransactionUseCase(
      ref.watch(dbProvider),
      afterSave: () {
        ref.read(budgetAlertProvider).sync();
        ref.read(autoSyncProvider).onSaved();
      },
    ));

/// 本機通知（N-1~N-10；預設 no-op——正式 flutter_local_notifications 屬 M2 接線；
/// 測試以 NotificationSpy override）。
final notificationProvider = Provider<NotificationService>((ref) {
  return const NoopNotificationService();
});

/// 預算警示（FR-B4；冪等 sync 點）。
final budgetAlertProvider = Provider(
    (ref) => BudgetAlertService(ref.watch(dbProvider), ref.watch(notificationProvider)));

/// no-op 通知（App 未接正式通知服務前行為；介面契約不變）。
class NoopNotificationService implements NotificationService {
  const NoopNotificationService();

  @override
  Future<void> notify(NotificationCall call) async {}

  @override
  Future<void> cancel(int id) async {}
}

/// 復原上一筆（FR-Q3）。
final undoLastTransactionProvider =
    Provider((ref) => UndoLastTransactionUseCase(ref.watch(dbProvider)));

/// 刪除交易（FR-T3：明細列刪除入口，F02-FE）。
final deleteTransactionProvider =
    Provider((ref) => DeleteTransactionUseCase(ref.watch(dbProvider)));

/// 帳單繳款（FR-C4；F04-FE）。
final repayStatementProvider = Provider(
    (ref) => RepayStatementUseCase(ref.watch(dbProvider), ref.watch(notificationProvider)));

/// 還原交易（FR-T3：「最近刪除」還原，F02-FE）。
final restoreTransactionProvider =
    Provider((ref) => RestoreTransactionUseCase(ref.watch(dbProvider)));

/// 永久刪除墓標（FR-T3：「最近刪除」→ 直接刪除／清空全部；PM 2026-10-24）。
final purgeTombstoneProvider =
    Provider((ref) => PurgeTombstoneUseCase(ref.watch(dbProvider)));

/// 待確認定期交易數（明細頁 badge；F06-FE）——確認/跳過後 refresh。
final recurringDueCountProvider =
    NotifierProvider<RecurringDueCountNotifier, int>(RecurringDueCountNotifier.new);

class RecurringDueCountNotifier extends Notifier<int> {
  @override
  int build() {
    ref.watch(dataVersionProvider);
    return _collect();
  }

  int _collect() {
    final db = ref.watch(dbProvider);
    final now = Clock.now();
    return db
        .dueSchedules(
            DateTime(now.year, now.month, now.day + 1).millisecondsSinceEpoch - 1)
        .length;
  }

  /// 確認/跳過後刷新（RecurringQueuePage 呼叫）。
  void refresh() => state = _collect();
}

/// **資料版本戳**（PM 2026-11-19：「所有的變更都要全畫面刷新」）。
///
/// 任何寫入（快記/掃描/匯入/帳戶/分類/預算/定期/還原/清空…）後呼叫
/// [refreshAllData]（＝bump 一次）；所有「讀 db 快取」型 provider watch 此戳
/// → 全 App 同步重算。此前各頁各自 invalidate 常有漏（新帳戶總覽/快記
/// 不出現＝實例）。
final dataVersionProvider =
    NotifierProvider<DataVersionNotifier, int>(DataVersionNotifier.new);

class DataVersionNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

extension RefreshAllDataRef on Ref {
  /// 任何資料寫入後呼叫——全部快取 provider 同步重算（全畫面刷新）。
  void refreshAllData() => read(dataVersionProvider.notifier).bump();
}

extension RefreshAllDataWidgetRef on WidgetRef {
  /// 同上（UI 層）。
  void refreshAllData() => read(dataVersionProvider.notifier).bump();
}

/// 未封存帳戶（快記/總覽）。
final activeAccountsProvider = Provider((ref) {
  ref.watch(dataVersionProvider); // 變更即重算（全畫面刷新）
  return ref.watch(dbProvider).allAccounts().where((a) => !a.archived).toList();
});

/// 支出分類（快記/分類設定）。
final expenseCategoriesProvider = Provider((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(dbProvider).categoriesByKind('expense');
});

/// 收入分類（設定頁分頁；與支出同源快取策略）。
final incomeCategoriesProvider = Provider((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(dbProvider).categoriesByKind('income');
});

/// 常用類別（FR-B1 常用區）：最近使用分類（依交易時間新→舊去重，取前 10）。
/// 監看 [ledgerProvider]——存帳後即時反映（下一筆選單最上方）。
final recentCategoryIdsProvider = Provider<List<String>>((ref) {
  final txs = ref.watch(ledgerProvider); // 已濾刪除＋occurred_at 降冪
  final seen = <String>{};
  final mru = <String>[];
  for (final t in txs) {
    final cat = t.categoryId;
    if (cat != null && seen.add(cat)) {
      mru.add(cat);
      if (mru.length >= 10) break;
    }
  }
  return mru;
});

/// 明細（未刪除交易，occurred_at 降冪；SDD 原則 2：衍生值一律重算）。
final ledgerProvider =
    NotifierProvider<LedgerNotifier, List<TxRow>>(LedgerNotifier.new);

class LedgerNotifier extends Notifier<List<TxRow>> {
  @override
  List<TxRow> build() {
    ref.watch(dataVersionProvider); // 任何寫入 → 明細重算（全畫面刷新）
    final txs = ref
        .watch(dbProvider)
        .allTransactions()
        .where((t) => t.deletedAt == null)
        .toList()
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return txs;
  }

  /// 儲存/復原後刷新（快記 controller 呼叫；明細即時反映 AC-02）。
  void refresh() => ref.invalidateSelf();
}

/// 最近刪除（墓標，deleted_at 降冪；F02-FE「最近刪除」頁）。
final recentDeletionsProvider =
    NotifierProvider<RecentDeletionsNotifier, List<TxRow>>(
        RecentDeletionsNotifier.new);

class RecentDeletionsNotifier extends Notifier<List<TxRow>> {
  @override
  List<TxRow> build() {
    ref.watch(dataVersionProvider);
    final txs = ref
        .watch(dbProvider)
        .allTransactions()
        .where((t) => t.deletedAt != null)
        .toList()
      ..sort((a, b) => b.deletedAt!.compareTo(a.deletedAt!));
    return txs;
  }

  /// 刪除/還原後刷新。
  void refresh() => ref.invalidateSelf();
}

// ── Row → 領域實體對映：移至 mappers.dart（頂部 export；服務層共用） ──

/// CSV 匯出存檔（PM 2026-11-19 修復：匯出只 print 未存檔）。
/// 平台實作見 platform/file_saver（native=存檔對話框、web=瀏覽器下載）。
final fileSaverProvider =
    Provider<FileSaver>((ref) => throw UnimplementedError(
        'fileSaverProvider 須於 main()/測試 override 注入'));
