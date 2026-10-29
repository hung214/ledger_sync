import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ledger_sync/platform/scan/image_qr_scan.dart';
import 'package:zxing2/qrcode.dart';

import '../helpers/invoice_qr_fixtures.dart';

/// PC 掃描＝**從圖片解 QR**（PM 2026-10-29 決策；`file_selector`＋`zxing2`＋`image`）。
///
/// 測試自行以 zxing2 編碼器**產生 QR 圖**再解回——完整覆蓋
/// 「影像 → 像素 → QR 文字 → 發票草稿」路徑（不需檔案對話框）。
void main() {
  /// 產生含單一 QR 的 PNG（白底黑模組＋4 模組 quiet zone）。
  Uint8List qrPng(String text, {int scale = 6}) {
    final matrix = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
    const quiet = 4;
    final size = (matrix.width + quiet * 2) * scale;
    final image = img.Image(width: size, height: size);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 0; y < matrix.height; y++) {
      for (var x = 0; x < matrix.width; x++) {
        if (matrix.get(x, y) == 1) {
          final px = (x + quiet) * scale;
          final py = (y + quiet) * scale;
          img.fillRect(image,
              x1: px,
              y1: py,
              x2: px + scale - 1,
              y2: py + scale - 1,
              color: img.ColorRgb8(0, 0, 0));
        }
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  /// 左右並排（台灣電子發票：左碼＋右明細碼）。
  Uint8List sideBySide(List<String> texts, {int scale = 6}) {
    final images = [for (final t in texts) img.decodeImage(qrPng(t, scale: scale))!];
    final w = images.fold<int>(0, (a, i) => a + i.width);
    final h = images.map((i) => i.height).reduce((a, b) => a > b ? a : b);
    final out = img.Image(width: w, height: h);
    img.fill(out, color: img.ColorRgb8(255, 255, 255));
    var x = 0;
    for (final i in images) {
      img.compositeImage(out, i, dstX: x, dstY: 0);
      x += i.width;
    }
    return Uint8List.fromList(img.encodePng(out));
  }

  test('單一左碼圖 → 解 QR → 發票草稿（號碼／日期／總額）', () {
    final png = qrPng(InvoiceQrFixtures.leftQr77);

    expect(ImageQrScanner.decodeQrTexts(png),
        contains(InvoiceQrFixtures.leftQr77));

    final draft = const ImageQrScanner().draftFromImage(png);
    expect(draft, isNotNull);
    expect(draft!.invoiceNo, InvoiceQrFixtures.expected.invoiceNo);
    expect(draft.sellerTaxId, InvoiceQrFixtures.expected.sellerTaxId);
    expect(draft.totalMinor.value, 195);
    expect(draft.date.value, DateTime(2026, 10, 18));
    expect(draft.isFallback, isFalse);
  });

  test('左右雙碼並排圖 → 兩碼都解出（切半找碼）→ 商家與明細一併帶入', () {
    final png = sideBySide([InvoiceQrFixtures.leftQr77, InvoiceQrFixtures.rightQr]);

    final texts = ImageQrScanner.decodeQrTexts(png);
    expect(texts, contains(InvoiceQrFixtures.leftQr77), reason: '左碼');
    expect(texts, contains(InvoiceQrFixtures.rightQr), reason: '右碼（切半解出）');

    final draft = const ImageQrScanner().draftFromImage(png);
    expect(draft?.merchant.value, '測試超商', reason: '商家來自右碼');
    expect(draft?.lineItems.length, 2, reason: '明細 2 項');
    expect(draft?.totalMinor.value, 195);
  });

  test('非 QR 圖 → 無文字；管線回退**空白確認卡**（S3.6）且保留原圖', () {
    final blank = img.Image(width: 240, height: 160);
    img.fill(blank, color: img.ColorRgb8(255, 255, 255));
    final bytes = Uint8List.fromList(img.encodePng(blank));

    expect(ImageQrScanner.decodeQrTexts(bytes), isEmpty);

    final item = const ImageQrScanner()
        .itemFromImage(bytes, now: DateTime(2026, 10, 29, 10));
    expect(item.draft.isFallback, isTrue, reason: '無法辨識 → 空白卡（手動補）');
    expect(item.draft.date.value, DateTime(2026, 10, 29), reason: '日期預填今天');
    expect(item.draft.totalMinor.value, isNull);
    expect(item.photoBytes, bytes, reason: '原圖保留為附件（FR-S4）');
  });

  test('草稿組裝：僅左碼 → 商家留空（舊式單碼發票；S3.2）', () {
    final d = ImageQrScanner.draftFromQrTexts([InvoiceQrFixtures.leftQr77]);
    expect(d, isNotNull);
    expect(d!.merchant.value, isNull);
    expect(d.totalMinor.value, 195);
    expect(ImageQrScanner.draftFromQrTexts(const []), isNull,
        reason: '無左碼 → null（呼叫端回退空白卡）');
  });
}
