import 'package:ledger_sync/domain/services/invoice_detail_codec.dart';

/// T-H6：發票掃描標準測資（QR 解析與金測共用；金額與 acceptance AC-03 一致：總額 195）。
class InvoiceQrFixtures {
  InvoiceQrFixtures._();

  /// 左側 QR（77 碼）：
  /// 發票號 AB12345678 ｜ 開立日 民國115/10/18 ｜ 隨機碼 1234 ｜ 賣方統編 12345678
  /// 銷售額 186 ｜ 課稅別 1（應稅）｜ 稅額 9 ｜ 總計 195 ｜ 保留 17 碼
  static const String leftQr77 =
      'AB12345678' '1151018' '1234' '12345678' '0000000186' '1' '0000000009' '0000000195' '00000000000000000';

  /// 右側 QR：明細（deflate＋Base32）。格式：賣方**品項**數量**單價**金額…
  static final String rightQr =
      InvoiceDetailCodec.encode('測試超商**咖啡**2**95**190**茶葉蛋**1**5**5');

  /// 標準欄位期望值（解析器驗收用）。
  static const expected = (
    invoiceNo: 'AB12345678',
    date: '1151018', // 民國 YYYMMDD = 2026-10-18
    sellerTaxId: '12345678',
    salesAmount: 186,
    taxAmount: 9,
    totalAmount: 195,
  );

  // --- 官方規格（財政部 v1.9）測資——PM 2026-11-22 根因修復 ---------------
  //
  // 真實世界樣本（2020 年實掃；欄位經逐碼驗證）：
  // 字軌 ZJ71292204｜民國109/03/12（2020-03-12）｜隨機 3612｜
  // 銷售額 0x00000055=85｜總計 0x00000059=89｜買方 00000000｜
  // 賣方 42308086｜加密驗證 24 碼（AES+Base64）。
  static const String officialLeftQr77 = 'ZJ71292204'
      '1090312'
      '3612'
      '00000055'
      '00000059'
      '00000000'
      '42308086'
      'N30oerT4xBGYFS89rT0n+Q==';

  /// 官方左碼＋延伸區：77 碼後接
  /// `:自行使用區(10):完整筆數:總筆數:編碼參數:品名:數量:單價…`（規格 §貳二）。
  /// 長度 115——真實發票左碼常為 90–130 字（PM 掃到的 118 字即此形）。
  static const String officialLeftWithItems =
      '$officialLeftQr77:**********:1:1:1:mask:1:45:snack:2:22';

  /// 官方右碼：`**` 起始＋品名:數量:單價…（規格 §貳二(二)）。
  static const String officialRightQr = '**milk:1:25:coffee:1:60';

  /// 官方右碼（中文品名——UTF-8 編碼參數場景；字串層解析用）。
  static const String officialRightQrCht = '**口罩:1:210:牛奶:1:25';

  /// 官方格式期望值。
  static const officialExpected = (
    invoiceNo: 'ZJ71292204',
    rocDate: '1090312', // 民國 109/03/12 = 2020-03-12
    sellerTaxId: '42308086',
    salesAmount: 85, // 0x00000055
    totalAmount: 89, // 0x00000059
  );
}

/// T-H6：OCR 文字 fixtures（紙本收據樣本——OCR 引擎 ML Kit/Vision 輸出之
/// 純文字版；BE 情境測 ReceiptFieldExtractor heuristics，不涉引擎）。
///
/// fixture 1（F03 S4/S7 標準測資，acceptance S3.5）欄位期望：
/// - 總額：關鍵字「總計」鄰近 195 → 信賴 0.9（≥0.7 不需複核）
/// - 日期：民國 115/10/18 → 2026/10/18——格式多義（須 +1911 換算、無明確
///   西元標記）→ 信賴 0.5（<0.7 需人工確認）
/// - 商家：頂部行「測試超商」→ 信賴 0.8
/// - 統編：**無 8 碼統編行** → 無候選 → 留空 null（非猜測，FR-S5）
class OcrReceiptFixtures {
  OcrReceiptFixtures._();

  static const String ocrText1 = '''
測試超商
台北市信義區測試路 1 號
115/10/18 12:30
咖啡 x2      190
茶葉蛋        5
總計        195
謝謝光臨
''';

  /// fixture {n}（1 起算；後續紙本樣本隨 FE 情境擴充）。
  static String text(int n) {
    switch (n) {
      case 1:
        return ocrText1;
      default:
        throw ArgumentError('OCR 文字 fixture $n 未定義（T-H6）');
    }
  }
}
