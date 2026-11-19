import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/import/csv_import_parser.dart';
import 'package:ledger_sync/application/import/import_models.dart';
import 'package:ledger_sync/application/reports/csv_exporter.dart';

import '../helpers/db_fixture.dart';

/// PM 2026-11-19 回歸：匯出 CSV → 再匯入，**來回必須相容**。
/// 此前三處斷點：①表頭「日期/時間」不在日期別名 ②值帶時間無對應格式
/// ③轉帳列未匯出轉入帳戶。
void main() {
  test('匯出 → 匯入：expense/income/transfer 全欄位語意一致', () async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedAccount(db, id: 'a-0', type: 'cash', name: '現金');
    await DbFixture.seedAccount(db, id: 'a-1', type: 'bank', name: '銀行');
    await DbFixture.seedTx(db,
        id: 't-e',
        kind: 'expense',
        amountMinor: 100,
        accountId: 'a-0',
        merchant: '早餐店',
        occurredAt: DateTime(2026, 11, 18, 8, 30).millisecondsSinceEpoch);
    await DbFixture.seedTx(db,
        id: 't-i',
        kind: 'income',
        amountMinor: 50000,
        accountId: 'a-1',
        merchant: '薪水',
        occurredAt: DateTime(2026, 11, 1, 9, 0).millisecondsSinceEpoch);
    await DbFixture.seedTx(db,
        id: 't-t',
        kind: 'transfer',
        amountMinor: 300,
        accountId: 'a-1',
        toAccountId: 'a-0',
        occurredAt: DateTime(2026, 11, 15, 21, 5).millisecondsSinceEpoch);

    final csv = CsvExporter(
      accountName: (id) => {'a-0': '現金', 'a-1': '銀行'}[id] ?? id,
    ).export(db.allTransactions());

    final r = CsvImportParser.parse(csv);
    expect(r.errors, isEmpty, reason: '來回匯入不應有解析錯誤');
    expect(r.rows.length, 3);
    expect(r.skippedCurrency, isEmpty);

    final byMerchant = {
      for (final row in r.rows) row.merchant: row,
    };
    final e = byMerchant['早餐店']!;
    expect(e.kind, ImportKind.expense);
    expect(e.amountMinor, 100);
    expect(e.date, DateTime(2026, 11, 18, 8, 30), reason: '日期＋時間');
    expect(e.account, '現金');

    final i = byMerchant['薪水']!;
    expect(i.kind, ImportKind.income);
    expect(i.amountMinor, 50000);

    final t = r.rows.singleWhere((row) => row.merchant == null || row.merchant!.isEmpty);
    expect(t.kind, ImportKind.transfer);
    expect(t.account, '銀行');
    expect(t.toAccount, '現金', reason: '轉入帳戶欄來回保留');
  });
}
