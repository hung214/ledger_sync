import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/import/csv_import_parser.dart';
import 'package:ledger_sync/application/import/import_models.dart';

/// AndroMoney CSV parser 單元測試（I3.2；合成 CSV——真實檔案到位後 I2 僅調別名表）。
void main() {
  group('分隔符偵測與表頭別名', () {
    test('中文表頭＋逗號', () {
      final csv = '日期,類型,金額,幣別,帳戶,分類,子分類,商家,備註\n'
          '2026/1/5,支出,195,TWD,現金,餐食,早餐,早餐店,你好\n';
      final r = CsvImportParser.parse(csv);
      expect(r.errors, isEmpty);
      expect(r.rows, hasLength(1));
      final row = r.rows.single;
      expect(row.kind, ImportKind.expense);
      expect(row.amountMinor, 19500);
      expect(row.account, '現金');
      expect(row.category, '餐食');
      expect(row.subcategory, '早餐');
      expect(row.merchant, '早餐店');
      expect(row.note, '你好');
      expect(row.date.year, 2026);
      expect(row.date.month, 1);
      expect(row.date.day, 5);
    });

    test('英文表頭＋Tab 分隔', () {
      final csv = 'Date\tType\tAmount\tAccount\tCategory\tNote\n'
          '2026-01-31\tIncome\t1000\tWallet\tSalary\tbonus\n';
      final r = CsvImportParser.parse(csv);
      expect(r.errors, isEmpty);
      expect(r.rows.single.kind, ImportKind.income);
      expect(r.rows.single.amountMinor, 100000);
      expect(r.rows.single.note, 'bonus');
    });

    test('引號欄位（含分隔符）', () {
      final csv = 'Date,Type,Amount,Account,Note\n'
          '2026-01-05,Expense,120,Cash,"拉麵, 加麵"\n';
      final r = CsvImportParser.parse(csv);
      expect(r.rows.single.note, '拉麵, 加麵');
    });
  });

  group('日期格式', () {
    test('多格式解析', () {
      final csv = '日期,類型,金額,帳戶\n'
          '2026-01-31,支出,1,現金\n'
          '2026/2/1,支出,2,現金\n'
          '2026年3月4日,支出,3,現金\n'
          '20260405,支出,4,現金\n'
          '1/5/2026,支出,5,現金\n';
      final r = CsvImportParser.parse(csv);
      expect(r.errors, isEmpty);
      expect(r.rows, hasLength(5));
      expect(r.rows[0].date.month, 1);
      expect(r.rows[1].date.month, 2);
      expect(r.rows[2].date.month, 3);
      expect(r.rows[3].date.month, 4);
      // M/d/yyyy 優先：1/5＝1月5日
      expect(r.rows[4].date.month, 1);
      expect(r.rows[4].date.day, 5);
    });
  });

  group('金額解析', () {
    test('千分位／負號／括號／貨幣符號／歐式', () {
      expect(CsvImportParser.parseAmountMinor('1,234'), 123400);
      expect(CsvImportParser.parseAmountMinor('1,234.56'), 123456);
      expect(CsvImportParser.parseAmountMinor('-99.5'), -9950);
      expect(CsvImportParser.parseAmountMinor('-NT\$1,000'), -100000);
      expect(CsvImportParser.parseAmountMinor('(1,234.56)'), -123456);
      expect(CsvImportParser.parseAmountMinor('1.234,56'), 123456, reason: '歐式');
      expect(CsvImportParser.parseAmountMinor('1.234'), 123400,
          reason: '三碼一組＝千分位');
      expect(CsvImportParser.parseAmountMinor('0'), 0);
      expect(CsvImportParser.parseAmountMinor(''), isNull);
      expect(CsvImportParser.parseAmountMinor('abc'), isNull);
    });
  });

  group('類型判定', () {
    test('中英＋空值以正負推定', () {
      expect(CsvImportParser.parseKind('支出', false), ImportKind.expense);
      expect(CsvImportParser.parseKind('Expense', false), ImportKind.expense);
      expect(CsvImportParser.parseKind('收入', false), ImportKind.income);
      expect(CsvImportParser.parseKind('Transfer', false), ImportKind.transfer);
      expect(CsvImportParser.parseKind('轉帳', false), ImportKind.transfer);
      expect(CsvImportParser.parseKind(null, true), ImportKind.expense,
          reason: '空類型＋負金額→支出');
      expect(CsvImportParser.parseKind(null, false), ImportKind.income);
      expect(CsvImportParser.parseKind('亂寫', false), isNull);
    });
  });

  group('錯誤列與幣別', () {
    test('壞日期／壞金額／缺帳戶／轉帳缺轉入——逐列錯誤不擋整批', () {
      final csv = '日期,類型,金額,帳戶\n'
          '不是日期,支出,10,現金\n'
          '2026/1/5,支出,abc,現金\n'
          '2026/1/6,支出,20,\n'
          '2026/1/7,轉帳,30,現金\n'
          '2026/1/8,支出,40,現金\n';
      final r = CsvImportParser.parse(csv);
      expect(r.rows, hasLength(1), reason: '僅最後一列可匯入');
      expect(r.errors, hasLength(4));
    });

    test('非 TWD → skippedCurrency（略過並標示）', () {
      final csv = 'Date,Type,Amount,Currency,Account\n'
          '2026-01-05,Expense,100,USD,Cash\n'
          '2026-01-06,Expense,200,twd,Cash\n';
      final r = CsvImportParser.parse(csv);
      expect(r.skippedCurrency, hasLength(1));
      expect(r.skippedCurrency.single.currency, 'USD');
      expect(r.rows.single.currency, 'TWD', reason: 'twd→正規化大寫');
    });

    test('幣別欄缺漏→預設 TWD', () {
      final csv = 'Date,Type,Amount,Account\n2026-01-05,Expense,100,Cash\n';
      final r = CsvImportParser.parse(csv);
      expect(r.rows.single.currency, 'TWD');
    });

    test('表頭缺必要欄位→整份失敗（fatal）', () {
      final csv = 'Date,Type,Account\n2026-01-05,Expense,Cash\n';
      final r = CsvImportParser.parse(csv);
      expect(r.rows, isEmpty);
      expect(r.errors.single.reason, contains('金額'));
    });
  });
}
