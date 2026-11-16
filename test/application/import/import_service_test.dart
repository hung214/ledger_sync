import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/import/import_models.dart';
import 'package:ledger_sync/application/import/import_service.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';

/// AndroMoney 匯入服務單元測試（I3.3/I3.4；合成 CSV）。
///
/// 驗收重點：①preview 統計正確（金額合計／期間／新帳戶分類）②apply 自動建立
/// 帳戶/分類＋交易入庫＋oplog（同 DB transaction 契約）③**去重＝日期＋金額＋
/// 備註＋帳戶**（PM 2026-11-16）④**重複匯入冪等**（重跑同檔 0 新增）。
void main() {
  late AppDatabase db;
  late ImportService service;

  const header = '日期,類型,金額,幣別,帳戶,轉入帳戶,分類,子分類,商家,備註\n';
  String csv(String rows) => '$header$rows';

  setUp(() {
    db = AppDatabase.inMemory();
    service = ImportService(db, deviceId: 'test-import');
  });

  tearDown(() => db.close());

  test('preview：金額合計／期間／新帳戶與新分類', () {
    final p = service.preview(csv(
        '2026/1/5,支出,195,TWD,現金,,餐食,早餐,早餐店,你好\n'
        '2026/1/6,收入,5000,TWD,薪轉戶,,薪水,,公司,\n'
        '2026/1/7,轉帳,1000,TWD,現金,薪轉戶,,,,\n'));
    expect(p.rows, hasLength(3));
    expect(p.totalsMinor[ImportKind.expense], 19500);
    expect(p.totalsMinor[ImportKind.income], 500000);
    expect(p.totalsMinor[ImportKind.transfer], 100000);
    expect(p.minDate!.month, 1);
    expect(p.minDate!.day, 5);
    expect(p.maxDate!.day, 7);
    expect(p.newAccounts, containsAll(['現金', '薪轉戶']));
    expect(p.newMainCategories['expense'], contains('餐食'));
    expect(p.newMainCategories['income'], contains('薪水'));
    expect(p.duplicateLines, isEmpty);
  });

  test('apply：自動建立帳戶/分類＋交易入庫（oplog 同步留痕）', () {
    final report = service.apply(csv(
        '2026/1/5,支出,195,TWD,現金,,餐食,早餐,早餐店,你好\n'
        '2026/1/7,轉帳,1000,TWD,現金,薪轉戶,,,,\n'));
    expect(report.inserted, 2);
    expect(report.transfersInserted, 1);
    expect(report.accountsCreated, 2, reason: '現金＋薪轉戶自動建立');
    expect(report.categoriesCreated, 2, reason: '主分類「餐食」＋子分類「早餐」');

    // 交易入庫＋欄位對映
    final txs = db.select(
        'SELECT kind, amount_minor, account_id, to_account_id, category_id, '
        'note, source FROM transactions ORDER BY occurred_at');
    expect(txs, hasLength(2));
    expect(txs[0]['kind'], 'expense');
    expect(txs[0]['amount_minor'], 19500);
    expect(txs[0]['source'], 'import');
    expect(txs[1]['kind'], 'transfer');
    expect(txs[1]['to_account_id'], isNotNull);
    expect(txs[1]['category_id'], isNull, reason: '轉帳無分類');

    // 帳戶/分類實際建立＋oplog 留痕
    expect(db.select("SELECT COUNT(*) c FROM accounts WHERE name='現金'")
        .first['c'], 1);
    expect(db.select("SELECT COUNT(*) c FROM oplog WHERE entity='accounts'")
        .first['c'], 2);
    expect(db.select("SELECT COUNT(*) c FROM oplog WHERE entity='categories'")
        .first['c'], 2);
    // 子分類掛在主分類之下
    final sub = db.select(
        "SELECT c.name FROM categories c JOIN categories p ON c.parent_id = p.id "
        "WHERE p.name = '餐食'");
    expect(sub.single['name'], '早餐');
  });

  test('去重：對 DB 已有交易（日期＋金額＋備註＋帳戶命中）→ 跳過', () {
    final c = csv('2026/1/5,支出,195,TWD,現金,,餐食,早餐,早餐店,你好\n');
    service.apply(c); // 第一次入庫
    final report = service.apply(c); // 重跑同檔
    expect(report.inserted, 0, reason: '重複匯入冪等');
    expect(report.skippedDuplicate, 1);
    expect(db.select('SELECT COUNT(*) c FROM transactions').first['c'], 1);
  });

  test('去重：預先存在同 DedupKey 之交易（非同檔）→ preview 即標記', () {
    // 先以服務入庫一筆「你好」
    service.apply(csv('2026/1/5,支出,195,TWD,現金,,餐食,早餐,早餐店,你好\n'));
    // 另一份檔：同日同額同帳戶同備註（不同商家——不影響 DedupKey）
    final p = service.preview(
        csv('2026/1/5,支出,195,TWD,現金,,餐食,早餐,超商,你好\n'));
    expect(p.duplicateLines, hasLength(1));
    expect(p.rows, isEmpty);
  });

  test('同備註不同金額 → 不算重複', () {
    service.apply(csv('2026/1/5,支出,195,TWD,現金,,餐食,早餐,早餐店,你好\n'));
    final p = service.preview(csv('2026/1/5,支出,196,TWD,現金,,餐食,早餐,早餐店,你好\n'));
    expect(p.rows, hasLength(1));
    expect(p.duplicateLines, isEmpty);
  });

  test('非 TWD 列：apply 不入庫且報告標示', () {
    final report = service.apply(csv(
        '2026/1/5,支出,100,USD,現金,,餐食,早餐,,\n'
        '2026/1/6,支出,200,TWD,現金,,餐食,早餐,,\n'));
    expect(report.inserted, 1);
    expect(report.skippedCurrencyRows, 1);
    expect(db.select('SELECT COUNT(*) c FROM transactions').first['c'], 1);
  });

  test('錯誤列：不入庫、報告計數', () {
    final report = service.apply(csv(
        '壞日期,支出,10,,現金\n'
        '2026/1/6,支出,20,,現金\n'));
    expect(report.inserted, 1);
    expect(report.errorRows, 1);
  });
}
