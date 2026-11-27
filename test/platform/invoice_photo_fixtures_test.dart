import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ledger_sync/platform/scan/image_qr_scan.dart';
import 'package:zxing2/qrcode.dart';

import '../helpers/invoice_qr_fixtures.dart';

/// **發票圖片自動測試**（PM 2026-11-22「是否需要發票圖片做自動測試？」——是）。
///
/// 背景：掃描失敗的根因是**解析器佈局與財政部官方規格 v1.9 不符**（金額
/// 十六進位、左碼 77 碼＋`:` 延伸區）——真實發票全平台（相機/PWA/檔案匯入）
/// 均無法解析，僅內部測資可過。本檔以**官方規格測資**跑完整管線
/// （影像 → zxing2 解碼 → 分類 → 解析 → 草稿），並模擬真實收據條件
/// （小模組、構圖、JPEG 壓縮）。
///
/// **真實照片 drop-in**：把掃描失敗的發票照片放進 `test/fixtures/invoices/`
/// 後執行 `flutter test test/platform/invoice_photo_fixtures_test.dart`——
/// 每張照片自動解碼＋解析並印出報告（個資目錄已 gitignore，不入版控）。
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

  /// 真實收據構圖：白底畫布＋頂部左右並排雙 QR＋灰色文字條（可含文字行）。
  Uint8List receiptPhoto(
    List<String> topTexts, {
    int canvasW = 1080,
    int canvasH = 1440,
    int scale = 3,
    int quality = 75,
    bool jpeg = true,
  }) {
    final images = [
      for (final t in topTexts) img.decodeImage(qrPng(t, scale: scale))!
    ];
    final out = img.Image(width: canvasW, height: canvasH);
    img.fill(out, color: img.ColorRgb8(255, 255, 255));
    // 雙 QR 上緣並排（官方規格：左右並列、水平上緣對齊）——
    // 左碼貼左、右碼貼右（真實證明聯構圖；切半偵測的關鍵假設）。
    img.compositeImage(out, images[0], dstX: 48, dstY: 48);
    if (images.length > 1) {
      img.compositeImage(out, images[1],
          dstX: canvasW - 48 - images[1].width, dstY: 48);
    }
    // 灰色文字條（商家名／品項／總計行）。
    var y = 48 + images.first.height + 40;
    for (var line = 0; line < 14; line++) {
      final w = canvasW - 96 - (line % 3) * 120;
      img.fillRect(out,
          x1: 48,
          y1: y,
          x2: 48 + w,
          y2: y + 14,
          color: img.ColorRgb8(120, 120, 120));
      y += 44;
    }
    return Uint8List.fromList(
        jpeg ? img.encodeJpg(out, quality: quality) : img.encodePng(out));
  }

  group('官方規格（財政部 v1.9）字串層解析', () {
    test('官方左碼 77 碼（金額十六進位）→ 總額/賣方統編/民國日期', () {
      final d = ImageQrScanner.draftFromQrTexts([InvoiceQrFixtures.officialLeftQr77]);
      expect(d, isNotNull);
      expect(d!.invoiceNo, InvoiceQrFixtures.officialExpected.invoiceNo);
      expect(d.totalMinor.value, 89, reason: '0x00000059 = 89（非十進位 59）');
      expect(d.date.value, DateTime(2020, 3, 12));
      expect(d.sellerTaxId, InvoiceQrFixtures.officialExpected.sellerTaxId);
      expect(d.merchant.value, isNull, reason: '官方 QR 無商家名稱');
    });

    test('官方左碼＋延伸區（115 字）→ 明細 2 項（左碼內品名:數量:單價）', () {
      final d = ImageQrScanner.draftFromQrTexts(
          [InvoiceQrFixtures.officialLeftWithItems]);
      expect(d, isNotNull);
      expect(d!.invoiceNo, InvoiceQrFixtures.officialExpected.invoiceNo,
          reason: '延伸區不影響固定區欄位');
      expect(d.totalMinor.value, 89);
      expect(d.lineItems.length, 2);
      expect(d.lineItems[0].name, 'mask');
      expect(d.lineItems[0].unitPrice, 45);
      expect(d.lineItems[1].name, 'snack');
      expect(d.lineItems[1].quantity, 2);
      expect(d.lineItems[1].amount, 44);
    });

    test('官方左＋右（** 品名:數量:單價）→ 左右明細合併', () {
      final d = ImageQrScanner.draftFromQrTexts(
          [InvoiceQrFixtures.officialLeftWithItems, InvoiceQrFixtures.officialRightQr]);
      expect(d, isNotNull);
      expect(d!.lineItems.length, 4, reason: '左碼延伸區 2 項＋右碼 2 項');
      expect(d.totalMinor.value, 89, reason: '總額以左碼總計額為準');
    });

    test('官方右碼中文品名（UTF-8）→ 口罩/牛奶', () {
      final d = ImageQrScanner.draftFromQrTexts(
          [InvoiceQrFixtures.officialLeftQr77, InvoiceQrFixtures.officialRightQrCht]);
      expect(d, isNotNull);
      expect(d!.lineItems.map((i) => i.name), containsAll(['口罩', '牛奶']));
    });

    test('前導 Byte-mode 標頭雜訊（2 字）→ 仍定位解析', () {
      const junk = '\u0001\u0002';
      final d = ImageQrScanner.draftFromQrTexts(
          ['$junk${InvoiceQrFixtures.officialLeftQr77}']);
      expect(d, isNotNull);
      expect(d!.invoiceNo, InvoiceQrFixtures.officialExpected.invoiceNo);
    });

    test('非發票 118 字碼（GR 形、欄位不合法）→ null（不產生錯誤交易）', () {
      // 模擬非官方格式之長條碼：金額欄含非十六進位字元。
      const unknown = 'GR306424081151107141'
          'ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ'
          'ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ'
          'ZZZZZZZZZZZZZZZZZZ';
      expect(unknown.length, 118);
      expect(ImageQrScanner.draftFromQrTexts([unknown]), isNull);
    });

    test('舊內部測資格式（SDD §5.4）不回歸——仍可解析', () {
      final d = ImageQrScanner.draftFromQrTexts(
          [InvoiceQrFixtures.leftQr77, InvoiceQrFixtures.rightQr]);
      expect(d, isNotNull);
      expect(d!.merchant.value, '測試超商');
      expect(d.totalMinor.value, 195);
    });
  });

  group('真實照片條件（收據構圖＋壓縮）', () {
    test('收據照片（雙 QR 上緣＋文字條，JPEG q75）→ 完整管線入單', () {
      final bytes = receiptPhoto([
        InvoiceQrFixtures.officialLeftWithItems,
        InvoiceQrFixtures.officialRightQr,
      ]);

      final texts = ImageQrScanner.decodeQrTexts(bytes);
      expect(texts, contains(InvoiceQrFixtures.officialLeftWithItems),
          reason: '左碼（含延伸區）');
      expect(texts, contains(InvoiceQrFixtures.officialRightQr),
          reason: '右碼（切半解出）');

      final draft = const ImageQrScanner().draftFromImage(bytes);
      expect(draft, isNotNull);
      expect(draft!.invoiceNo, InvoiceQrFixtures.officialExpected.invoiceNo);
      expect(draft.totalMinor.value, 89);
      expect(draft.lineItems.length, 4);
    });

    test('同構圖走相機輕量路徑（3 區）→ 兩碼都解出', () {
      final bytes = receiptPhoto([
        InvoiceQrFixtures.officialLeftWithItems,
        InvoiceQrFixtures.officialRightQr,
      ]);
      final result = const ImageQrScanner().draftFromCameraFrame(bytes);
      expect(result, isNotNull);
      expect(result!.draft!.invoiceNo, InvoiceQrFixtures.officialExpected.invoiceNo);
      expect(result.draft!.lineItems.length, 4);
    });

    test('PNG（非壓縮）同構圖 → 一致結果', () {
      final bytes = receiptPhoto([
        InvoiceQrFixtures.officialLeftWithItems,
        InvoiceQrFixtures.officialRightQr,
      ], jpeg: false);
      final draft = const ImageQrScanner().draftFromImage(bytes);
      expect(draft, isNotNull);
      expect(draft!.totalMinor.value, 89);
    });
  });

  group('透印去除與中央變焦（PM 2026-11-22 實測情境）', () {
    test('透印去除：背面印刷（中灰雜訊）干擾下仍可解', () {
      final base =
          img.decodeImage(qrPng(InvoiceQrFixtures.officialLeftQr77, scale: 4))!;
      // 背面印刷透光模擬：**只染白底**（真實透印不會蓋掉正面深黑印刷）——
      // 白色像素改為中灰 150（背面文字透印）。
      final noisy = img.Image.from(base);
      for (var y = 0; y < noisy.height; y += 2) {
        for (var x = 0; x < noisy.width; x++) {
          final p = noisy.getPixel(x, y);
          final l = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
          if (l > 200) {
            noisy.setPixel(x, y, img.ColorRgb8(150, 150, 150));
          }
        }
      }
      final bytes = Uint8List.fromList(img.encodePng(noisy));
      expect(ImageQrScanner.decodeQrTexts(bytes),
          contains(InvoiceQrFixtures.officialLeftQr77),
          reason: '硬閾值二值化洗掉中灰透印，正面深黑 QR 保留');
    });

    test('中央裁切變焦：遠距小 QR（佔畫面約 1/5）→ draftFromCameraFrame 命中',
        () {
      // 1600×1200 白底，QR 置中（佔寬約 1/8）——整張/切半特徵不足。
      final qr = img.decodeImage(
          qrPng(InvoiceQrFixtures.officialLeftWithItems, scale: 3))!;
      final out = img.Image(width: 1600, height: 1200);
      img.fill(out, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(out, qr,
          dstX: (1600 - qr.width) ~/ 2, dstY: (1200 - qr.height) ~/ 2);
      final bytes = Uint8List.fromList(img.encodeJpg(out, quality: 80));

      final result = const ImageQrScanner().draftFromCameraFrame(bytes);
      expect(result, isNotNull, reason: '中央 70%/50% 裁切＝數位變焦——遠距可解');
      expect(result!.draft!.invoiceNo, InvoiceQrFixtures.officialExpected.invoiceNo);
    });
  });

  group('T91 ROI 子區解碼（hold 階段右側限區）', () {
    test('收據右半 ROI → 只解出右碼（decodeRegionRgba）', () {
      final bytes = receiptPhoto([
        InvoiceQrFixtures.officialLeftWithItems,
        InvoiceQrFixtures.officialRightQr,
      ]);
      final full = img.decodeImage(bytes)!;
      // 右半 ROI（模擬 hold 階段取景框右半的限區）。
      final roi = img.copyCrop(full,
          x: full.width ~/ 2,
          y: 0,
          width: full.width - full.width ~/ 2,
          height: full.height);
      final rgba = roi
          .convert(numChannels: 4)
          .getBytes(order: img.ChannelOrder.rgba);
      final texts = ImageQrScanner.decodeRegionRgba(
          Uint8List.fromList(rgba), roi.width, roi.height);
      expect(texts, contains(InvoiceQrFixtures.officialRightQr),
          reason: '右半 ROI 內的右碼可解');
      expect(texts, everyElement(startsWith('**')),
          reason: '左碼在左半——不在 ROI 範圍（限區生效）');
    });

    test('空白 ROI → 空清單（不拋錯——例外防護契約）', () {
      expect(ImageQrScanner.decodeRegionRgba(
          Uint8List(16 * 16 * 4), 16, 16), isEmpty);
      expect(
          ImageQrScanner.decodeRegionRgba(Uint8List(0), 0, 0), isEmpty);
    });
  });

  group('真實發票照片（drop-in fixtures）', () {
    final dir = Directory('test/fixtures/invoices');
    final photos = <File>[
      for (final e in (dir.existsSync() ? dir.listSync() : const <FileSystemEntity>[]))
        if (e is File &&
            const ['jpg', 'jpeg', 'png', 'webp', 'bmp'].contains(
                e.path.split('.').last.toLowerCase()))
          e,
    ];
    final placeholder = photos.isEmpty;
    test('放入照片即自動執行（test/fixtures/invoices/README.md）', () {
      // 佔位說明——真實照片存在時此組自動展開為逐張測試。
      expect(dir.existsSync() || true, isTrue);
    }, skip: placeholder ? '把掃描失敗的發票照片放入 test/fixtures/invoices/ 後重跑' : false);

    for (final photo in photos) {
      test('照片 ${photo.uri.pathSegments.last} → 解碼＋解析報告', () {
        final bytes = photo.readAsBytesSync();
        final texts = ImageQrScanner.decodeQrTexts(bytes);
        // ignore: avoid_print
        print('[$photo] 解出 ${texts.length} 條：');
        for (final t in texts) {
          // ignore: avoid_print
          print('  RAW(${t.length})=$t'); // **完整內容**——非官方格式時對症分析
        }
        final draft = ImageQrScanner.draftFromQrTexts(texts);
        // ignore: avoid_print
        print(draft == null
            ? (texts.isEmpty
                ? '  → 解出 0 條（紙本無 QR＝預期——APP 內走 OCR/手動；'
                    '有 QR 但解不出＝照片品質/構圖問題）'
                : '  → 解析失敗（解出但非官方格式——見上方 RAW）')
            : '  → ✓ invoiceNo=${draft.invoiceNo} 總額=${draft.totalMinor.value} '
                '日期=${draft.date.value} 賣方統編=${draft.sellerTaxId} '
                '明細=${draft.lineItems.length} 項');
        // 診斷階段：**軟性斷言**（管線不崩＋照片留存即可）——
        // 逐張期望值待格式確認後再收緊。
        expect(photo.existsSync(), isTrue);
      });
    }
  });
}
