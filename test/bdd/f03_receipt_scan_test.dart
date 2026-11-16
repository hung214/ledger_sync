import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ledger_sync/application/quick_entry/save_transaction_use_case.dart';
import 'package:ledger_sync/application/scan/attachment_store.dart';
import 'package:ledger_sync/application/scan/blob_store_factory.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/domain/entities/transaction_draft.dart';
import 'package:ledger_sync/domain/services/invoice_qr_parser.dart';
import 'package:ledger_sync/domain/services/receipt_field_extractor.dart';

import '../helpers/db_fixture.dart';
import '../helpers/gherkin/gherkin.dart';
import '../helpers/in_memory_cloud_adapter.dart';
import '../helpers/invoice_qr_fixtures.dart';

/// F03-BE 情境執行器（@BE @M4 @FR-S，7 情境：QR 解析/明細合併/回退/
/// OCR 信賴度/附件定址/離線/效能）。
///
/// 來源：specs/plan/tests/backend/F03_receipt-scan.feature（sync 同步副本，
/// 禁止手改副本）。句型登記簿：specs/plan/tests/dsl.md §2（v0.6）。
/// 測資：T-H6 InvoiceQrFixtures（77 碼左 QR/右 QR 產生器）＋OcrReceiptFixtures。
void main() {
  final source = File('test/bdd/F03_receipt-scan.feature').readAsStringSync();
  final doc = GherkinParser.parse(source);

  test('F03-BE：發票掃描解析與附件（7 情境）', () async {
    final w = _World();
    final runner = GherkinRunner();
    _bind(runner, w);

    try {
      final executed = await runner.run(doc, tagFilter: (tags) => tags.contains('@BE'));
      expect(executed, 7, reason: 'F03-BE 應執行 7 個情境');
      // ignore: avoid_print
      print(runner.log.join('\n'));
    } finally {
      Clock.unfreeze();
      for (final db in w.dbs) {
        db.close();
      }
      // 測試衛生：清本輪各情境之 blobs 暫存目錄（忽略已不存在）。
      for (final dir in w.blobDirs) {
        // ignore: avoid_catches_without_on_clauses
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  });
}

/// 情境共享狀態（每 Scenario 由 Background 重置）。
class _World {
  final List<AppDatabase> dbs = [];
  late AppDatabase db;
  final accounts = <String, String>{};
  late SaveTransactionUseCase save;
  late Directory blobsDir;
  final blobDirs = <Directory>[]; // tearDown 清理用
  final InMemoryCloudAdapter cloud = InMemoryCloudAdapter();
  bool offline = false;

  /// QR 解析草稿（S1/S2）；解析失敗為 null（S3）。
  TransactionDraft? draft;
  bool parseUnrecognized = false;

  /// S3 回退空白確認卡。
  TransactionDraft? fallbackDraft;

  /// OCR 欄位抽取結果（S4/S7）。
  OcrExtraction? extraction;

  /// S5 原圖 bytes 與落地附件。
  List<int> originalBytes = const [];
  StoredAttachment? stored;
  String? lastTxId;

  /// S7 計時。
  Duration lastElapsed = Duration.zero;
}

void _bind(GherkinRunner runner, _World w) {
  // ── Given：環境 ─────────────────────────────────────────
  runner.on(r'已重置記憶體資料庫$', (p) async {
    final db = DbFixture.create();
    w.dbs.add(db);
    w.db = db;
    w.accounts.clear();
    w.offline = false;
    w.cloud.reset();
    w.draft = null;
    w.parseUnrecognized = false;
    w.fallbackDraft = null;
    w.extraction = null;
    w.originalBytes = const [];
    w.stored = null;
    w.lastTxId = null;
    w.lastElapsed = Duration.zero;
    w.save = SaveTransactionUseCase(db);
    w.blobsDir = await Directory.systemTemp.createTemp('ledger_blobs');
    w.blobDirs.add(w.blobsDir);
  });

  runner.on(r'已建立帳戶「{name}」類型 {type} 期初 {amount}$', (p) {
    final id = 'a-${w.accounts.length}';
    DbFixture.seedAccount(
      w.db,
      id: id,
      type: p['type']!,
      name: p['name']!,
      opening: _amount(p['amount']!),
    );
    w.accounts[p['name']!] = id;
  });

  // S5：T-H6 原圖 fixture（4000x3000，image 套件動態生成——encodePng）。
  runner.on(r'一張 4000x3000 原圖 fixture$', (p) {
    final photo = img.Image(width: 4000, height: 3000);
    w.originalBytes = img.encodePng(photo);
  });

  // S6：連線關閉（dsl §2.1——in-memory adapter failing 態；FR-S3 全本機斷言前提）。
  runner.on(r'連線已關閉$', (p) {
    w.cloud.failing = true;
    w.offline = true;
  });

  // ── When：解析與儲存 ─────────────────────────────────────
  // 雙 QR 先於單 QR（前綴碰撞教訓——dsl §1）。
  runner.on(r'解析左側 QR 字串 {qr} 與右側 QR 字串 {rqr}$', (p) {
    final left = _stripQuotes(p['qr']!);
    final rawRight = _stripQuotes(p['rqr']!);
    // `<明細測資: ...>` 哨兵 → T-H6 rightQr（deflate+Base32 產生器）。
    final right = rawRight.startsWith('<明細測資:') ? InvoiceQrFixtures.rightQr : rawRight;
    w.draft = InvoiceQrParser.parse(left, right);
    w.parseUnrecognized = w.draft == null;
  });

  runner.on(r'解析左側 QR 字串 {qr}$', (p) {
    w.draft = InvoiceQrParser.parseLeft(_stripQuotes(p['qr']!));
    w.parseUnrecognized = w.draft == null;
  });

  // 計時變體先於 base（NFR-02）。
  runner.on(r'對 OCR 文字 fixture {n} 執行欄位抽取（計時）$', (p) {
    final sw = Stopwatch()..start();
    w.extraction = ReceiptFieldExtractor.extract(OcrReceiptFixtures.text(int.parse(p['n']!)));
    w.lastElapsed = sw.elapsed;
  });

  runner.on(r'對 OCR 文字 fixture {n} 執行欄位抽取$', (p) {
    w.extraction = ReceiptFieldExtractor.extract(OcrReceiptFixtures.text(int.parse(p['n']!)));
  });

  // S5：附件儲存流程＝確認卡儲存（SDD §5.4：SaveTransactionUseCase source=scan
  // ＋附件存檔——交易與附件關聯於此建立）。
  runner.on(r'執行附件儲存流程$', (p) async {
    final saved = w.save.execute(
      accountId: w.accounts['現金']!,
      amountMinor: 195,
      occurredAt: Clock.now(),
      source: 'scan',
    );
    w.lastTxId = saved.transactionId;
    final store = AttachmentStore(w.db, newBlobStore(dirPath: w.blobsDir.path));
    w.stored = await store.save(
      imageBytes: w.originalBytes,
      transactionId: saved.transactionId,
      mime: 'image/jpeg',
    );
  });

  // ── Then：解析結果斷言（統編版先註冊） ──────────────────────
  runner.on(r'解析結果：商家統編={id}、總額={amt}、日期={date}$', (p) {
    final draft = w.draft;
    expect(draft, isNotNull, reason: '左 QR 應解析成功（77 碼）');
    expect(draft!.sellerTaxId, _stripQuotes(p['id']!), reason: 'FR-S1：賣方統編');
    expect(draft.totalMinor.value, _amount(p['amt']!), reason: 'FR-S1：總額');
    expect(draft.date.value, _date(p['date']!), reason: 'FR-S1：開立日（民國→西元）');
  });

  runner.on(r'校驗：銷售額 {s} \+ 稅額 {t} = 總額 {total} 通過$', (p) {
    final draft = w.draft;
    expect(draft, isNotNull, reason: '校驗通過＝解析器驗證未拒絕（SDD §5.4）');
    final sales = int.parse(p['s']!);
    final tax = int.parse(p['t']!);
    final total = int.parse(p['total']!);
    expect(sales + tax, total, reason: '銷售額＋稅額＝總計（應稅）');
    expect(draft!.totalMinor.value, total, reason: '草稿總額＝校驗總額');
  });

  runner.on(r'解析結果：商家={m}$', (p) {
    expect(w.draft, isNotNull, reason: '雙 QR 應合併成功');
    expect(w.draft!.merchant.value, _stripQuotes(p['m']!), reason: 'FR-S2：右 QR 賣方名稱');
  });

  runner.on(r'明細含 {items}$', (p) {
    final draft = w.draft;
    expect(draft, isNotNull);
    final items = p['items']!.split(' 與 ');
    for (final text in items) {
      final item = _parseItem(text.trim());
      final hit = draft!.lineItems
          .where((li) => li.name == item.name && li.quantity == item.quantity
              && li.unitPrice == item.unitPrice && li.amount == item.amount)
          .isNotEmpty;
      expect(hit, isTrue, reason: 'FR-S2：明細應含 $text');
    }
  });

  runner.on(r'顯示「無法辨識此發票格式」且不建立草稿$', (p) {
    expect(w.parseUnrecognized, isTrue, reason: 'FR-S2：非發票格式');
    expect(w.draft, isNull, reason: '不得建立發票草稿');
  });

  runner.on(r'建立空白確認卡（日期=今天）供手動輸入$', (p) {
    final now = Clock.now();
    final fallback = TransactionDraft.blank(now);
    w.fallbackDraft = fallback;
    expect(fallback.isFallback, isTrue);
    expect(fallback.date.value, DateTime(now.year, now.month, now.day),
        reason: 'FR-S2：回退卡日期=今天');
    expect(fallback.totalMinor.value, isNull, reason: '總額留空供手動輸入');
    expect(fallback.merchant.value, isNull, reason: '商家留空');
  });

  runner.on(r'解析結果：總額={amt}、日期={date}（信賴度 {conf}）$', (p) {
    final ext = w.extraction;
    expect(ext, isNotNull, reason: 'OCR 欄位抽取應產出結果');
    expect(ext!.totalMinor.value, _amount(p['amt']!), reason: 'FR-S5：總額抽取');
    expect(ext.date.value, _date(p['date']!), reason: 'FR-S5：日期抽取');
    expect(ext.date.confidence, double.parse(p['conf']!),
        reason: 'acceptance S3.5：日期欄信賴 0.5');
  });

  runner.on(r'信賴度 < 0.7 的欄位標記為「需人工確認」$', (p) {
    final ext = w.extraction!;
    expect(ext.date.needsReview, isTrue, reason: 'FR-S5：0.5 < 0.7 須標記');
    expect(ext.totalMinor.needsReview, isFalse, reason: '總額 0.9 ≥ 0.7');
    expect(ext.merchant.needsReview, isFalse, reason: '商家 0.8 ≥ 0.7');
  });

  runner.on(r'無法判定的欄位為留空（非猜測值）$', (p) {
    final ext = w.extraction!;
    expect(ext.sellerTaxId.value, isNull, reason: 'FR-S5：無統編候選→留空非猜測');
  });

  // ── Then：附件（FR-S4） ──────────────────────────────────
  runner.on(r'附件縮至最長邊 1600px、JPEG q70$', (p) async {
    final stored = w.stored;
    expect(stored, isNotNull);
    // P4：經 BlobStore 讀回（native=檔案；語意同）。JPEG 魔數＋尺寸驗證不變。
    final store = AttachmentStore(w.db, newBlobStore(dirPath: w.blobsDir.path));
    final bytes = (await store.read(stored!.sha256))!;
    // JPEG 魔數（SOI FFD8）＋最長邊 1600（image 套件解碼驗尺寸）。
    expect(bytes[0], 0xFF);
    expect(bytes[1], 0xD8, reason: 'JPEG SOI');
    final decoded = img.decodeImage(bytes);
    expect(decoded, isNotNull);
    final longest = decoded!.width >= decoded.height ? decoded.width : decoded.height;
    expect(longest, 1600, reason: 'FR-S4：原圖 4000x3000 → 最長邊 1600');
    expect(AttachmentStore.jpegQuality, 70);
  });

  runner.on(r'檔名 = blobs/{name}（內容定址）$', (p) async {
    final stored = w.stored;
    expect(stored, isNotNull);
    final store = AttachmentStore(w.db, newBlobStore(dirPath: w.blobsDir.path));
    final bytes = await store.read(stored!.sha256);
    expect(bytes, isNotNull, reason: 'blob 以 sha256 為鍵（SDD §5.4）');
    expect(sha256.convert(bytes!).toString(), stored.sha256,
        reason: '內容定址：鍵=壓縮後內容之 sha256');
  });

  runner.on(r'attachments 資料列建立且關聯交易$', (p) {
    final stored = w.stored!;
    final rows = w.db.attachmentsForTransaction(w.lastTxId!);
    expect(rows, hasLength(1), reason: 'FR-S4：附件列落地且關聯交易');
    expect(rows.first.sha256, stored.sha256);
    expect(rows.first.byteSize, stored.byteSize);
    // oplog 契約（attachments 屬 sync_entity；與附件列同 DB transaction）。
    final ops = w.db.allOps().where((o) => o.entity == 'attachments').toList();
    expect(ops, hasLength(1));
    expect(ops.first.payload, isNotNull, reason: '整列快照（非墓標）');
    expect(ops.first.packedSeq, isNull, reason: '未打包（F07 打包）');
  });

  runner.on(r'解析結果：總額={amt}（無網路呼叫斷言）$', (p) {
    expect(w.offline, isTrue, reason: 'FR-S3 前提：連線關閉態');
    final draft = w.draft;
    expect(draft, isNotNull, reason: '離線下照常解析（全本機）');
    expect(draft!.totalMinor.value, _amount(p['amt']!), reason: 'FR-S3：解析結果正確');
  });

  runner.on(r'效能：OCR 欄位抽取耗時 {ms}ms < {limit}ms$', (p) {
    final limit = int.parse(p['limit']!);
    expect(w.lastElapsed.inMilliseconds, lessThan(limit),
        reason: 'NFR-02：單張 OCR 抽取 < ${limit}ms（實測 ${w.lastElapsed.inMilliseconds}ms）');
  });
}

// ── 解析輔助 ─────────────────────────────────────────────

String _stripQuotes(String s) => s.trim().replaceAll('"', '');

int _amount(String s) {
  final n = int.tryParse(s);
  if (n != null) return n;
  return int.parse(s.replaceAll(',', ''));
}

DateTime _date(String s) {
  final parts = s.split(RegExp(r'[/-]'));
  return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
}

/// 明細項文字：「品名 數量×單價=金額」或「品名 金額」（短式）。
({String name, int quantity, int unitPrice, int amount}) _parseItem(String text) {
  final full = RegExp(r'^(.+?) (\d+)×(\d+)=(\d+)$').firstMatch(text);
  if (full != null) {
    return (
      name: full.group(1)!,
      quantity: int.parse(full.group(2)!),
      unitPrice: int.parse(full.group(3)!),
      amount: int.parse(full.group(4)!),
    );
  }
  final short = RegExp(r'^(.+?) (\d+)$').firstMatch(text);
  expect(short, isNotNull, reason: '明細項格式無法解析：$text');
  // 短式「品名 金額」＝數量 1、單價＝金額（acceptance「茶葉蛋 5」＝1 顆 5 元）。
  final amount = int.parse(short!.group(2)!);
  return (name: short.group(1)!, quantity: 1, unitPrice: amount, amount: amount);
}
