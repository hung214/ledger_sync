import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/scan/paper_barcode.dart';

/// 紙本發票**一維條碼**解析（官方規格 §壹：Code 39——
/// `*` + 年期別(5) + 字軌號碼(10) + 隨機碼(4) + `*`）。
/// PM 2026-11-22：紙本發票模式＝掃此條碼帶出發票號碼＋年月提示。
void main() {
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
