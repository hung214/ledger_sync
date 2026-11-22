import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/scan/paper_barcode.dart';
import 'package:ledger_sync/platform/ocr/text_ocr.dart';
import 'dart:ui' show Rect;

/// 紙本發票**一維條碼**解析（官方規格 §壹：Code 39——
/// `*` + 年期別(5) + 字軌號碼(10) + 隨機碼(4) + `*`）。
/// PM 2026-11-22：紙本發票模式＝掃此條碼帶出發票號碼＋年月提示。
/// T21：OcrLine 帶框擷取（確認卡照片上框出辨識位置）。
void ocrBoxTests() {
  group('findInvoiceNoWithBox（OcrLine＋區域框）', () {
    test('同行命中 → 回傳發票號＋該行框', () {
      final hit = findInvoiceNoWithBox([
        const OcrLine('中華民國115年'),
        const OcrLine('EF', box: Rect.fromLTWH(0.1, 0.4, 0.08, 0.05)),
        const OcrLine('20947672', box: Rect.fromLTWH(0.1, 0.5, 0.3, 0.05)),
      ]);
      // 分行配對：字軌 EF＋號碼 20947672 → 框＝兩行聯集
      expect(hit, isNotNull);
      expect(hit!.$1, 'EF20947672');
      expect(hit.$2, isNotNull);
      expect(hit.$2!.left, 0.1, reason: '聯集框左界');
      expect(hit.$2!.top, 0.4, reason: '聯集框上界');
    });

    test('同行直配 → 框＝該行', () {
      final hit = findInvoiceNoWithBox([
        const OcrLine('收銀機發票'),
        const OcrLine('EF-20947672', box: Rect.fromLTWH(0.2, 0.3, 0.4, 0.06)),
      ]);
      expect(hit!.$1, 'EF20947672');
      expect(hit.$2!.left, 0.2);
    });

    test('無發票號 → null', () {
      expect(
          findInvoiceNoWithBox(
              [const OcrLine('總計 195', box: Rect.fromLTWH(0, 0, 1, 1))]),
          isNull);
    });
  });
}

void main$() {
  test('官方範例：*10404UZ176908720122* → 發票號 UZ17690872＋2015/03', () {
    final r = parsePaperBarcode('*10404UZ176908720122*');
    expect(r, isNotNull);
    expect(r!.invoiceNo, 'UZ17690872');
    expect(r.dateHint, DateTime(2015, 3, 1), reason: '104年 → 2015；期別04 → 3-4月首月');
  });

  test('引擎回傳不含星號 → 仍可解析（114年11-12月期）', () {
    final r = parsePaperBarcode('11412SR303936034759');
    expect(r, isNotNull);
    expect(r!.invoiceNo, 'SR30393603');
    expect(r.dateHint, DateTime(2025, 11, 1), reason: '114年；期別12 → 11-12月首月');
  });

  test('長度/格式不合 → null（QR 內容、網址等不誤判）', () {
    expect(parsePaperBarcode('https://example.com'), isNull);
    expect(parsePaperBarcode('*10404UZ17690872012*'), isNull, reason: '18 碼');
    expect(parsePaperBarcode('*10404UZ1769087201223*'), isNull, reason: '20 碼');
    expect(
        parsePaperBarcode('*1040412345678901234*'), isNull, reason: '字軌非 2 英文');
  });

  test('期別非雙數月 → null（規格：期別＝雙數月）', () {
    expect(parsePaperBarcode('*10403UZ176908720122*'), isNull);
  });
}

/// 紙本發票 **OCR 發票號擷取**（T12，PM 2026-11-22：紙本無條碼、
/// 只有印刷發票號碼——Apple Vision 文字辨識後的正則擷取）。
void ocrTests() {
  group('findInvoiceNo（OCR 文字行 → 發票號）', () {
    test('常見印刷格式', () {
      expect(findInvoiceNo(['發票號 AB-12345678']), 'AB12345678');
      expect(findInvoiceNo(['AB 12345678']), 'AB12345678');
      expect(findInvoiceNo(['ab12345678']), 'AB12345678', reason: '大小寫容錯');
      expect(findInvoiceNo(['_total 105', 'BJ98765432']), 'BJ98765432');
    });
    test('無發票號 → null（金額/日期不誤判）', () {
      expect(findInvoiceNo(['總計 195', '2026/11/22']), isNull);
      expect(findInvoiceNo(const []), isNull);
    });

    test('PM 實照 2075：字軌/號碼分兩行 → EF20947672', () {
      expect(
          findInvoiceNo([
            'フト', 'EF', '中華民國115年9-10月份', '收銀機統冬發票', '《收執聯）',
            '20947672', '南崁解屬', 'ND:95019084', '桃闔市麓竹鼷崧孝窮簬3號',
            'TEL:03-3226789', '日期20260913 時間1234',
          ]),
          'EF20947672');
    });

    test('PM 實照 2076：標籤行後的數字優先（40668100＝賣方統編位置不誤選）', () {
      expect(
          findInvoiceNo([
            '7SS', '40668100', 'EF', '中華民國115年9-10月份', '收鈱機統',
            '營票', '收執聯）', '26987585', '9=10', '中華民國', 'ERERUBL', '健鹽联',
          ]),
          'EF26987585', reason: '號碼緊接「收執聯」——非最近的 40668100');
    });

    test('印刷日期：2075「日期20260913」→ 2026-09-13', () {
      expect(
          findPrintedDate([
            'フト', 'EF', '中華民國115年9-10月份', '20947672', 'ND:95019084',
            '日期20260913 時間1234',
          ]),
          DateTime(2026, 9, 13));
    });

    test('印刷日期：「115年9-10月份」標籤不得誤判為交易日期', () {
      expect(findPrintedDate(['中華民國115年9-10月份', '收銀機發票']), isNull);
    });
  });
}

void main() {
  main$();
  ocrTests();
  ocrBoxTests();
}

