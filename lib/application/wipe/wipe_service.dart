import 'dart:convert';

import '../../core/clock.dart';
import '../../core/hlc.dart';
import '../../data/sqlite/app_database.dart';
import '../../platform/cloud/cloud_storage_adapter.dart';
import '../scan/blob_store.dart';
import '../first_run_bootstrap.dart';

/// 雲端資料已被清除（WipeService 清空後其他裝置之 pull 偵測——FR-O3
/// 「不復活」：vault 缺 → 視為雲端已重置 → 停止同步（不推回舊資料））。
class CloudWipedException implements Exception {
  const CloudWipedException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 資料清除服務（FR-O3；SDD §7.3）：本地全表清空＋附件檔案刪除；
/// 含雲端 → LedgerSync/ 整個資料夾刪除（vault/devices/ops/blobs/backups）。
class WipeService {
  WipeService(this._db, {this.cloud, this.blobs});

  final AppDatabase _db;

  /// 雲端 adapter（null＋含雲端=false＝未連結語意——頁面層無須注入）。
  final CloudStorageAdapter? cloud;

  /// 附件 blob 儲存（P6 起以 [BlobStore] 平台分流——native=檔案、web=IndexedDB；
  /// null＝略）。
  final BlobStore? blobs;

  static const _tables = [
    'statement_items', 'refund_links', 'attachments', 'installment_plans',
    'statements', 'credit_card_details', 'income_goals', 'budgets',
    'recurring_transactions', 'transactions', 'templates', 'categories',
    'accounts', 'oplog', 'settings', 'sync_events',
  ];

  /// 刪除範圍（PM 2026-10-24：資料管理可**勾選**要清除的範圍）。
  ///
  /// 「回到系統預設值」＝[wipe]（全清空）＋下次啟動重新播種內建集，
  /// 不在本列舉內（語意為重置而非局部刪除）。
  static const scopeOrder = [
    WipeScope.transactions,
    WipeScope.categories,
    WipeScope.accounts,
    WipeScope.budgets,
  ];

  /// 局部刪除（PM 2026-10-24）：以**刪除＋oplog**表達（多裝置合併一致——
  /// 其他裝置 pull 後套用刪除；與 [wipe] 的 hard delete 全清空語意不同）。
  ///
  /// - `transactions`：所有未刪除交易（軟刪除墓標＋oplog NULL payload）
  /// - `categories`：**預設以外**類別（使用者自建；內建 id 集見
  ///   [FirstRunBootstrap.builtInCategoryIds]）
  /// - `accounts`：所有帳戶
  /// - `budgets`：所有預算（軟刪除）
  void wipeScoped(Set<WipeScope> scopes, {required String deviceId}) {
    if (scopes.isEmpty) return;
    final now = Clock.now().millisecondsSinceEpoch;
    String hlcOf() => Hlc.now(deviceId).toString();

    if (scopes.contains(WipeScope.transactions)) {
      for (final t in _db.allTransactions()) {
        if (t.deletedAt != null) continue;
        final h = hlcOf();
        _db.softDeleteTransactionWithOplog(
          t.id,
          OplogRow(
              entity: 'transactions',
              entityId: t.id,
              hlc: h,
              payload: null, // 墓標（SDD §5.5.4：NULL=刪除）
              packedSeq: null),
          deletedAt: now,
          hlc: h,
        );
      }
    }
    if (scopes.contains(WipeScope.categories)) {
      final builtIn = FirstRunBootstrap.builtInCategoryIds;
      for (final kind in ['expense', 'income']) {
        for (final c in _db.categoriesByKind(kind)) {
          if (c.deletedAt != null) continue;
          if (c.isSystem || builtIn.contains(c.id)) continue; // 預設以外
          final h = hlcOf();
          _db.mutateCategoryWithOplog(
            c,
            OplogRow(
                entity: 'categories',
                entityId: c.id,
                hlc: h,
                payload: jsonEncode(c.toSnapshot()),
                packedSeq: null),
            delete: true,
          );
        }
      }
    }
    if (scopes.contains(WipeScope.accounts)) {
      for (final a in _db.allAccounts()) {
        final h = hlcOf();
        _db.mutateAccountWithOplog(
          a,
          OplogRow(
              entity: 'accounts',
              entityId: a.id,
              hlc: h,
              payload: jsonEncode(a.toSnapshot()),
              packedSeq: null),
          delete: true,
        );
      }
    }
    if (scopes.contains(WipeScope.budgets)) {
      for (final b in _db.allBudgets()) {
        final h = hlcOf();
        _db.softDeleteBudgetWithOplog(b.id, now,
            OplogRow(entity: 'budgets', entityId: b.id, hlc: h, payload: null, packedSeq: null));
      }
    }
  }

  /// 執行清空（FR-O3）：[includeCloud] 時連雲端 LedgerSync/ 一併刪除。
  Future<void> wipe({required bool includeCloud}) async {
    // 本地：全表清空（事務全有全無）。
    _db.runInTransaction(() {
      for (final t in _tables) {
        _db.clearTable(t);
      }
    });
    // 附件刪除（P6：平台分流——native=檔案目錄、web=IndexedDB store 清空）。
    await blobs?.deleteAll();
    // 雲端：根清單逐一刪除（adapter 無 rmdir——逐檔；資料夾語意由路徑前綴）。
    if (includeCloud) {
      final adapter = cloud;
      if (adapter == null) {
        throw const FormatException('含雲端清空須提供雲端 adapter');
      }
      final all = await adapter.list('');
      for (final path in all) {
        await adapter.delete(path);
      }
    }
  }
}

/// 局部刪除範圍（PM 2026-10-24）。標籤為 UI 契約。
enum WipeScope {
  transactions('明細（交易）'),
  categories('預設以外類別'),
  accounts('帳戶'),
  budgets('預算');

  const WipeScope(this.label);
  final String label;
}
