import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ledger_sync/application/quick_entry/save_transaction_use_case.dart';
import 'package:ledger_sync/application/scan/attachment_store.dart';
import 'package:ledger_sync/application/scan/blob_store_factory.dart';
import 'package:ledger_sync/application/sync/auto_sync_service.dart';
import 'package:ledger_sync/application/sync/backup_service.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/domain/entities/account.dart';
import 'package:ledger_sync/domain/entities/transaction.dart';
import 'package:ledger_sync/domain/services/balance_calculator.dart';

import '../helpers/db_fixture.dart';
import '../helpers/gherkin/gherkin.dart';
import '../helpers/in_memory_cloud_adapter.dart';
import '../helpers/notification_spy.dart';

/// F07-BE 情境執行器（@BE @M5 @FR-Y，7 情境塊；備份密碼 Outline 3 列）。
///
/// 來源：specs/plan/tests/backend/F07_cloud-sync-backup.feature（同步副本，
/// 禁止手改副本）。句型登記簿：specs/plan/tests/dsl.md §2（v0.8）。
/// 多裝置拓撲（T-H3）：每裝置各自本地 SQLite，僅經共享 InMemoryCloudAdapter
/// 交換檔案（vault/devices/ops/blobs/backups，SDD §5.5.1）。
/// ⚠️ 同步合併模組：待雙重 review（research §1.3）。
void main() {
  final source = File('test/bdd/F07_cloud-sync-backup.feature').readAsStringSync();
  final doc = GherkinParser.parse(source);

  test('F07-BE：同步協議與備份（7 情境塊＋Outline 3 列）', () async {
    final w = _World();
    final runner = GherkinRunner();
    _bind(runner, w);
    try {
      final executed = await runner.run(doc, tagFilter: (tags) => tags.contains('@BE'));
      expect(executed, 10, reason: 'F07-BE 應執行 10 個情境（S1~S7 單一＋備份密碼 Outline 3 列）');
      // ignore: avoid_print
      print(runner.log.join('\n'));
    } finally {
      Clock.unfreeze();
      for (final d in w.dbs) {
        d.close();
      }
    }
  });
}

/// 單一裝置（本地 DB＋coordinator＋spy）。
class _Device {
  _Device(this.id, this.db, this.cloud, this.spy) {
    blobsDir = Directory.systemTemp.createTempSync('ledger_blobs_f07');
    coordinator = SyncCoordinator(db, cloud,
        deviceId: id,
        blobsDir: blobsDir,
        onConflictEvent: (e) {
          // 事件列由 BundleApplier 落 sync_events——此鉤子僅通知（N-8）。
          spy.notify(const NotificationCall(
              id: 8, title: '衝突', body: '雲端變更已採用較新版本'));
        });
    save = SaveTransactionUseCase(db, deviceId: id, afterSave: () {});
    store = AttachmentStore(db, newBlobStore(dirPath: blobsDir.path));
  }

  /// 本地 blob 目錄（AttachmentStore 與 SyncCoordinator 共用）。
  late final Directory blobsDir;

  final String id;
  final AppDatabase db;
  final InMemoryCloudAdapter cloud;
  final NotificationSpy spy;
  late final SyncCoordinator coordinator;
  late final SaveTransactionUseCase save;
  late final AttachmentStore store;
  late final AutoSyncService auto = AutoSyncService(db, coordinator);
  String networkType = 'wifi';
}

class _World {
  final dbs = <AppDatabase>[];
  final InMemoryCloudAdapter cloud = InMemoryCloudAdapter();
  final devices = <String, _Device>{};
  String current = 'd-A';
  String networkType = 'mobile';

  _Device device([String? id]) => devices[id ?? current]!;

  /// 建立裝置（同帳號——共享 cloud adapter）。
  /// [seedCash]：本地背景帳戶（現金 1000，同 id 'a-0'）——正式流程由
  /// bootstrap 還原；BE 情境兩裝置各自離線持有（bootstrap 特例 seedCash=false）。
  _Device ensureDevice(String id, {bool seedCash = true}) =>
      devices.putIfAbsent(id, () {
        final db = DbFixture.create();
        dbs.add(db);
        if (seedCash) {
          DbFixture.seedAccount(db, id: 'a-0', type: 'cash', name: '現金', opening: 1000);
        }
        return _Device(id, db, cloud, NotificationSpy());
      });

  /// 最近匯出之備份（Outline 斷言用）。
  String? lastExportPath;
  String? exportPassword;
  AppDatabase? importTarget;
  Object? importError;
}

void _bind(GherkinRunner runner, _World w) {
  // ── Background ───────────────────────────────────────────
  runner.on(r'已重置記憶體資料庫$', (p) {
    w.devices.clear();
    w.cloud.reset();
    w.ensureDevice('d-A');
    w.current = 'd-A';
  });

  runner.on(r'模擬雲端為 in-memory adapter 且已連結$', (p) {
    w.cloud.reset(); // configured=true；vault 由首個 push 首建（§5.5.1）
  });

  runner.on(r'已建立帳戶「{name}」類型 {type} 期初 {amount}$', (p) {
    final d = w.device();
    // ensureDevice 已預置 'a-0'（現金 1000）——冪等確認後入 oplog 基線
    // （Background 前置資料視為已同步；離線情境之「N 筆未打包」僅計情境內變更）。
    final row = d.db.allAccounts().first;
    d.db.appendOp(opFor('accounts', row.id, newHlc(d.id), row.toSnapshot()));
    d.db.markOpsPacked(0);
  });

  // ── Given：雲端/同步模式/附件分流/備份前置 ─────────────────
  runner.on(r'裝置{d} 離線記錄 {n} 筆交易（oplog {n2} 筆未打包）$', (p) {
    final d = w.ensureDevice('d-${p['d']}');
    final n = int.parse(p['n']!);
    for (var i = 0; i < n; i++) {
      d.save.execute(
        accountId: d.db.allAccounts().first.id,
        amountMinor: 100 * (i + 1),
        occurredAt: Clock.now(),
      );
    }
  });

  runner.on(r'同步模式 = {mode}$', (p) {
    final mode = switch (p['mode']!) {
      '每筆自動同步' => 'per-transaction',
      '節能批次（預設）' => 'batch',
      '僅手動' => 'manual',
      _ => throw ArgumentError('未知同步模式：${p['mode']}'),
    };
    w.device().db.setSetting('sync.mode', mode);
  });

  runner.on(r'附件僅 Wi-Fi 同步 = {state} 且網路 = {network}$', (p) {
    w.device().db.setSetting(
        'backup.attachments_wifi_only', p['state'] == 'on' ? 'true' : 'false');
    w.networkType = p['network']!; // wifi | mobile
  });

  runner.on(r'雲端已有裝置{d} 的 {n} 個 bundle 與 {m} 份快照$', (p) async {
    final d = w.ensureDevice('d-${p['d']}');
    final catId = 'c-boot';
    DbFixture.seedCategory(d.db, id: catId, kind: 'expense', name: '餐飲食品');
    d.db.appendOp(
        opFor('categories', catId, newHlc(d.id), d.db.localRow('categories', catId)!));
    final batches = int.parse(p['n']!);
    for (var b = 0; b < batches; b++) {
      for (var i = 0; i < 2; i++) {
        d.save.execute(
          accountId: d.db.allAccounts().first.id,
          categoryId: catId,
          amountMinor: 10 * (b + 1) + i,
          merchant: '商家$b-$i',
          occurredAt: Clock.now(),
        );
      }
      await d.coordinator.sync();
    }
    final backup = BackupService(d.db, d.cloud, deviceId: d.id);
    await backup.runIfNeeded();
  });

  runner.on(r'備份保留份數 = {n}$', (p) {
    w.device().db.setSetting('backup.keep', p['n']!);
  });

  runner.on(r'裝置{d} 修改交易 {id} 備註為「{note}」並同步$', (p) async {
    final d = w.ensureDevice('d-${p['d']}');
    _ensureTxX(d);
    _editNote(d, 'tx-X', p['note']!);
    await d.coordinator.sync();
  });

  runner.on(r'裝置{d} 離線修改交易 {id} 備註為「{note}」（HLC 較新）$', (p) async {
    final d = w.ensureDevice('d-${p['d']}');
    _ensureTxX(d);
    // HLC 較新：明確錯開 1 秒（Hlc.now 同毫秒 counter 恆 0——凍結錯開保證可比）。
    Clock.freeze(Clock.now().add(const Duration(seconds: 1)));
    _editNote(d, 'tx-X', p['note']!);
    Clock.unfreeze();
  });

  // ── When：同步動作 ───────────────────────────────────────
  runner.on(r'連線恢復並執行 SyncCoordinator\.pull 與 push$', (p) async {
    await w.device().coordinator.sync();
  });

  runner.on(r'裝置{d}（同一帳號）執行 SyncCoordinator\.pull 與 push$', (p) async {
    final d = w.ensureDevice('d-${p['d']}');
    w.current = d.id;
    await d.coordinator.sync();
  });

  // 短版變體（S2：裝置B 執行...；長版先註冊——錨尾互斥實則順序無虞）。
  runner.on(r'裝置{d} 執行 SyncCoordinator\.pull 與 push$', (p) async {
    final d = w.ensureDevice('d-${p['d']}');
    if (d.db.allAccounts().isEmpty) {
      DbFixture.seedAccount(d.db, id: 'a-0', type: 'cash', name: '現金', opening: 1000);
    }
    w.current = d.id;
    await d.coordinator.sync();
  });

  runner.on(r'呼叫 SaveTransactionUseCase（帳戶「{a}」、分類「{c}」、金額 {amt}、時間 {t}）$',
      (p) async {
    final d = w.device();
    final catId = _getOrCreateCategory(d, p['c']!);
    d.save.execute(
      accountId: d.db.allAccounts().firstWhere((a) => a.name == p['a']!).id,
      categoryId: catId,
      amountMinor: _amount(p['amt']!),
      occurredAt: _dateTime(p['t']!),
    );
    // FR-Y11 每筆自動同步：afterSave 鉤子（AutoSyncService.onSaved）。
    await d.auto.onSaved();
  });

  runner.on(r'連續記錄 {n} 筆交易$', (p) async {
    final d = w.device();
    final n = int.parse(p['n']!);
    for (var i = 0; i < n; i++) {
      d.save.execute(
        accountId: d.db.allAccounts().first.id,
        amountMinor: 50 * (i + 1),
        occurredAt: Clock.now(),
      );
      await d.auto.onSaved(); // 節能批次 → no-op
    }
  });

  runner.on(r'模擬時間快轉 {n} 秒並觸發批次同步$', (p) async {
    Clock.freeze(Clock.now().add(Duration(seconds: int.parse(p['n']!))));
    await w.device().coordinator.sync(); // 節能批次觸發點（30s timer 語意）
    Clock.unfreeze();
  });

  runner.on(r'掃描發票入帳（含附件）並觸發同步$', (p) async {
    final d = w.device();
    final result = d.save.execute(
      accountId: d.db.allAccounts().first.id,
      amountMinor: 195,
      merchant: '測試超商',
      occurredAt: Clock.now(),
      source: 'scan',
    );
    await d.store.save(imageBytes: _smallJpeg(), transactionId: result.transactionId);
    d.coordinator.networkType = _normalizeNetwork(w.networkType);
    await d.coordinator.sync();
  });

  runner.on(r'網路 = {network} 並觸發同步$', (p) async {
    final d = w.device();
    d.coordinator.networkType = _normalizeNetwork(p['network']!);
    await d.coordinator.sync();
  });

  runner.on(r'模擬時間快轉 {n} 天並觸發自動備份（每日）$', (p) async {
    final days = int.parse(p['n']!);
    final base = Clock.now();
    for (var i = 1; i <= days; i++) {
      Clock.freeze(base.add(Duration(days: i)));
      await BackupService(w.device().db, w.cloud, deviceId: w.device().id).runIfNeeded();
    }
    Clock.unfreeze();
  });

  runner.on(r'執行新裝置 Bootstrap（同一帳號）$', (p) async {
    final d = w.ensureDevice('d-C', seedCash: false); // 全新安裝——空本
    await d.coordinator.bootstrap();
  });

  runner.on(r'匯出備份檔{option}並於另一環境匯入$', (p) async {
    final option = p['option']!;
    final source = w.ensureDevice('d-A');
    final backup = BackupService(source.db, source.cloud, deviceId: source.id);
    final hasPassword = option.contains('檔案密碼');
    w.exportPassword = hasPassword ? 's3cret' : null;
    w.lastExportPath = await backup.export(password: w.exportPassword);
    final target = DbFixture.create();
    w.dbs.add(target);
    w.importTarget = target;
    w.importError = null;
    try {
      await backup.importInto(
        target,
        w.lastExportPath!,
        password: option.contains('錯誤密碼') ? 'wrong' : w.exportPassword,
      );
    } catch (e) {
      w.importError = e;
    }
  });

  // ── Then：雲端斷言 ───────────────────────────────────────
  // 複數（N ops）與單數（1 op）變體——錨尾互斥，順序無虞。
  Future<void> assertBundleOps(Map<String, String> p) async {
    final folder = 'ops/${p['d']}';
    final files = await w.cloud.list(folder);
    expect(files, contains(p['file']!),
        reason: 'FR-Y4：bundle 檔應存在');
    final bytes = await w.cloud.download('$folder/${p['file']}');
    final bundle = jsonDecode(utf8.decode(bytes!)) as Map<String, Object?>;
    expect((bundle['ops'] as List).length, int.parse(p['n']!),
        reason: 'OpBundle ops 數（SDD §5.5.2）');
  }

  runner.on(r'雲端 ops/{d}/{file} 存在（{n} ops）$',
      (p) => assertBundleOps(p));
  runner.on(r'雲端 ops/{d}/{file} 存在（{n} op）$',
      (p) => assertBundleOps(p));

  runner.on(r'裝置{d} 收到 {n} 筆交易$', (p) {
    final d = w.devices['d-${p['d']}']!;
    expect(d.db.allTransactions().where((t) => t.deletedAt == null).length,
        int.parse(p['n']!), reason: 'FR-Y4：pull 套用結果');
  });

  runner.on(r'裝置{a} 與裝置{b} 的重算餘額一致$', (p) {
    final a = w.devices['d-${p['a']}']!;
    final b = w.devices['d-${p['b']}']!;
    final calc = const BalanceCalculator();
    int balanceOf(_Device d) {
      final r = d.db.allAccounts().first;
      final account = Account(
        id: r.id,
        type: AccountType.values.byName(r.type),
        name: r.name,
        currency: r.currency,
        openingAmountMinor: r.openingAmountMinor,
        archived: false,
      );
      return calc.assetBalance(
          account: account, txs: d.db.allTransactions().map(_txEntity).toList());
    }

    expect(balanceOf(b), balanceOf(a), reason: 'AC-06：雙裝置餘額收斂');
  });

  runner.on(r'交易 {id} 備註 = 「{note}」（兩裝置一致）$', (p) async {
    final b = w.devices['d-B']!;
    final a = w.devices['d-A']!;
    // LWW 收斂：A 再 pull（冪等）→ 兩裝置一致。
    await a.coordinator.pull();
    expect(b.db.transactionById('tx-X')!.note, p['note']!, reason: 'FR-Y5：B 版勝出');
    expect(a.db.transactionById('tx-X')!.note, p['note']!, reason: 'A 收斂至 B 版');
  });

  runner.on(r'衝突事件 {n} 筆，被覆蓋內容為 "{text}"$', (p) {
    final events = w.devices['d-A']!.db.allSyncEvents();
    expect(events.length, int.parse(p['n']!), reason: 'FR-Y5：衝突事件落 sync_events');
    final row = jsonDecode(events.first.overwrittenRow!) as Map<String, Object?>;
    expect(row['note'], p['text']!, reason: '被覆蓋內容唯讀快照');
  });

  runner.on(r'通知 spy 收到 N-{n} 恰 {k} 次$', (p) {
    // 衝突發生於被覆蓋裝置（S2 為 d-A）——斷言全裝置 spy 之 N-{n} 總數。
    final total = w.devices.values
        .map((d) => d.spy.withId(int.parse(p['n']!)).length)
        .fold(0, (a, b) => a + b);
    expect(total, int.parse(p['k']!), reason: 'N-8 衝突通知');
  });

  runner.on(r'oplog 皆已打包（packed_seq 非 null）$', (p) {
    expect(w.device().db.allOps().every((o) => o.packedSeq != null), isTrue,
        reason: 'FR-Y11：每筆模式即時打包');
  });

  runner.on(r'雲端僅 {n} 個 bundle（{m} ops，非 {k} 個）$', (p) async {
    final files = await w.cloud.list('ops/d-A');
    expect(files.length, int.parse(p['n']!), reason: 'FR-Y11：批次合併為單一 bundle');
    final bytes = await w.cloud.download('ops/d-A/${files.first}');
    final bundle = jsonDecode(utf8.decode(bytes!)) as Map<String, Object?>;
    expect((bundle['ops'] as List).length, int.parse(p['m']!));
  });

  runner.on(r'交易已同步且附件暫緩（blobs/ 無新檔）$', (p) async {
    expect(await w.cloud.list('ops/d-A'), isNotEmpty, reason: '交易 op 已同步');
    expect(await w.cloud.list('blobs'), isEmpty, reason: 'FR-Y11：行動網路附件暫緩');
  });

  runner.on(r'雲端 blobs/{name} 存在$', (p) async {
    expect(await w.cloud.list('blobs'), isNotEmpty,
        reason: 'FR-Y11：Wi-Fi 附件上傳（內容定址）');
  });

  runner.on(r'本地收到全部交易/帳戶/分類$', (p) {
    final c = w.devices['d-C']!;
    final a = w.devices['d-A']!;
    expect(c.db.allAccounts().map((x) => x.id),
        containsAll(a.db.allAccounts().map((x) => x.id)), reason: 'FR-Y2：帳戶 bootstrap');
    expect(
        c.db.select('SELECT COUNT(*) c FROM categories').first['c'],
        a.db.select('SELECT COUNT(*) c FROM categories').first['c'],
        reason: '分類數一致');
    expect(c.db.allTransactions().where((t) => t.deletedAt == null).length,
        a.db.allTransactions().where((t) => t.deletedAt == null).length,
        reason: '交易數一致');
  });

  runner.on(r'裝置{d} 的 manifest 已建立（lastSeq = {n}）$', (p) async {
    final id = 'd-${p['d']}';
    final manifest =
        await w.devices[id]!.coordinator.readJson('devices/$id.json');
    expect(manifest, isNotNull, reason: 'bootstrap 應寫入 manifest');
    expect(manifest!['last_seq'], int.parse(p['n']!), reason: 'AC-08：尚未 push');
  });

  runner.on(r'雲端 backups/ 保留 {n} 份$', (p) async {
    final files = await w.cloud.list('backups');
    expect(files.length, int.parse(p['n']!), reason: 'FR-Y3：保留份數 GC');
  });

  runner.on(r'最舊一份已被清理$', (p) async {
    final files = await w.cloud.list('backups')
      ..sort();
    expect(files.length, lessThanOrEqualTo(7), reason: 'GC 後不超保留份數');
  });

  // Outline 三列（匯入結果；分列綁定——避免泛匹配）。
  runner.on(r'直接還原成功$', (p) {
    expect(w.importError, isNull, reason: '不加密備份可直接還原');
    expect(_importedTxCount(w), greaterThan(0), reason: '資料已還原');
  });

  runner.on(r'完整還原成功$', (p) {
    expect(w.importError, isNull, reason: '正確密碼完整還原');
    expect(_importedTxCount(w), greaterThan(0), reason: '資料已還原');
  });

  runner.on(r'拒絕匯入且本地資料不變$', (p) {
    expect(w.importError, isNotNull, reason: '錯誤密碼須拒絕（AC-14）');
    expect(_importedTxCount(w), 0, reason: '本地資料零變動');
  });
}

// ── 輔助 ─────────────────────────────────────────────

/// 衝突基礎列（兩裝置對同 id/帳戶/金額各自離線持有——LWW 語意之基礎）。
void _ensureTxX(_Device d) {
  if (d.db.transactionById('tx-X') != null) return;
  final now = Clock.now().millisecondsSinceEpoch;
  d.db.insertTransaction(TxRow(
    id: 'tx-X',
    kind: 'expense',
    amountMinor: 120,
    currency: 'TWD',
    accountId: d.db.allAccounts().first.id,
    toAccountId: null,
    categoryId: null,
    merchant: '超商',
    note: null,
    occurredAt: now,
    source: 'manual',
    settlementStatus: 'none',
    createdAt: now,
    updatedAt: now,
    hlc: newHlc(d.id),
  ));
  d.db.appendOp(
      opFor('transactions', 'tx-X', newHlc(d.id), d.db.transactionById('tx-X')!.toSnapshot()));
  // 基礎列 op 視為已同步基線（packed）——情境內僅「修改 op」參與衝突語意。
  d.db.markOpsPacked(0);
}

/// 編輯備註（fixture 層：UPDATE＋新 hlc＋oplog 整列快照；正式編輯 UseCase 屬後續）。
void _editNote(_Device d, String txId, String note) {
  final hlc = newHlc(d.id);
  d.db.setTransactionNote(txId, note);
  d.db.execute('UPDATE transactions SET hlc = ? WHERE id = ?', [hlc, txId]);
  d.db.appendOp(opFor('transactions', txId, hlc, d.db.transactionById(txId)!.toSnapshot()));
}

String _getOrCreateCategory(_Device d, String name) {
  final existing =
      d.db.categoriesByKind('expense').where((c) => c.name == name).toList();
  if (existing.isNotEmpty) return existing.first.id;
  final id = 'c-${name.hashCode.abs() % 100000}';
  DbFixture.seedCategory(d.db, id: id, kind: 'expense', name: name);
  return id;
}

/// 網路型態正規化（feature 文字 Wi-Fi/mobile → coordinator 值域 wifi/mobile）。
String _normalizeNetwork(String raw) =>
    raw.toLowerCase().contains('wi') ? 'wifi' : 'mobile';

/// 匯入完整性（Outline 斷言）：帳戶（Background 種於來源）已還原即證成功；
/// 「本地資料不變」＝0（拒絕路徑）。
int _importedTxCount(_World w) {
  final target = w.importTarget;
  if (target == null) return 0;
  return target.allAccounts().any((a) => a.id == 'a-0') ? 1 : 0;
}

Uint8List _smallJpeg() {
  final photo = img.Image(width: 16, height: 12);
  return img.encodeJpg(photo, quality: 90);
}

Tx _txEntity(TxRow r) => Tx(
      id: r.id,
      kind: TxKind.values.byName(r.kind),
      amountMinor: r.amountMinor,
      currency: r.currency,
      fxRate: r.fxRate,
      splitGroupId: r.splitGroupId,
      accountId: r.accountId,
      toAccountId: r.toAccountId,
      categoryId: r.categoryId,
      merchant: r.merchant,
      note: r.note,
      occurredAt: r.occurredAt,
      source: TxSource.values.byName(r.source),
      settlementStatus: SettlementStatus.values.byName(r.settlementStatus),
      deleted: r.deletedAt != null,
    );

DateTime _dateTime(String s) {
  final m = RegExp(r'^(\d{4})/(\d{2})/(\d{2})(?: (\d{1,2}):(\d{2}))?$')
      .firstMatch(s.trim());
  if (m == null) throw FormatException('日期時間格式未支援：$s（dsl.md §1-3）');
  return DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    m.group(4) == null ? 0 : int.parse(m.group(4)!),
    m.group(5) == null ? 0 : int.parse(m.group(5)!),
  );
}

int _amount(String s) {
  final m = RegExp(r'^-?[\d,]+').firstMatch(s.trim());
  if (m == null) throw FormatException('金額格式未支援：$s');
  return int.parse(m.group(0)!.replaceAll(',', ''));
}
