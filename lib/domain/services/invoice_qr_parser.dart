import 'dart:convert';

import '../../domain/entities/invoice_line_item.dart';
import '../../domain/entities/transaction_draft.dart';
import '../../domain/services/invoice_detail_codec.dart';

/// 台灣電子發票 QR 解析（SDD §5.4 InvoiceQrParser——領域層純 Dart）。
///
/// 左 QR（77 碼）欄位切片：
/// `[0,10)` 發票字軌號碼、`[10,17)` 開立日期（民國 YYYMMDD）、`[17,21)` 隨機碼、
/// `[21,29)` 賣方統編、`[29,39)` 銷售額、`[39,40)` 課稅別、`[40,50)` 稅額、
/// `[50,60)` 總金額；餘為保留碼。
///
/// 右 QR：deflate(raw)＋Base32（字元集 0-9A-Z，T-H6 codec）解出
/// 「賣方名稱**品項**數量**單價**金額…」。
///
/// 驗證（SDD §5.4）：長度、`銷售額 + 稅額 ≈ 總計`（應稅時）、日期合理性；
/// 不合規回 null → 呼叫端回退手動輸入（FR-S2，訊息 [unrecognizedMessage]）。
class InvoiceQrParser {
  InvoiceQrParser._();

  /// FR-S2 回退訊息（BE/FE 共用常數——acceptance S3.6 文案）。
  static const String unrecognizedMessage = '無法辨識此發票格式';

  /// 解析左 QR（單張：無明細）。無法辨識回 null（不拋錯——回退是正常路徑）。
  ///
  /// 欄位切片（SDD §5.4）：[0,10) 發票號、[10,17) 民國 YYYMMDD、[17,21)
  /// 隨機碼、[21,29) 賣方統編、[29,39) 銷售額、[39,40) 課稅別、[40,50)
  /// 稅額、[50,60) 總金額；[60,77) 保留碼。驗證：長度 77、數值欄可解析、
  /// 應稅（課稅別 1）時銷售額＋稅額＝總計、日期合理（FR-S1；失敗→ FR-S2 回退）。
  static TransactionDraft? parseLeft(String qr) {
    if (qr.length != 77) return null;
    final invoiceNo = qr.substring(0, 10);
    final dateStr = qr.substring(10, 17);
    final sellerTaxId = qr.substring(21, 29);
    final sales = int.tryParse(qr.substring(29, 39));
    final taxType = qr.substring(39, 40);
    final tax = int.tryParse(qr.substring(40, 50));
    final total = int.tryParse(qr.substring(50, 60));
    if (sales == null || tax == null || total == null) return null;

    // 應稅（課稅別 1）：銷售額＋稅額＝總計（SDD §5.4 驗證）。
    if (taxType == '1' && sales + tax != total) return null;

    // 日期合理性：民國 YYYMMDD → 西元（+1911）；2/30 等不存在的日期拒絕。
    final y = int.tryParse(dateStr.substring(0, 3));
    final m = int.tryParse(dateStr.substring(3, 5));
    final d = int.tryParse(dateStr.substring(5, 7));
    if (y == null || m == null || d == null) return null;
    if (y < 100 || m < 1 || m > 12 || d < 1 || d > 31) return null;
    final date = DateTime(y + 1911, m, d);
    if (date.year != y + 1911 || date.month != m || date.day != d) return null;

    return TransactionDraft(
      merchant: const DraftField.none(), // 商家名稱在右 QR（明細碼）
      totalMinor: DraftField(total, 1.0),
      date: DraftField(date, 1.0),
      sellerTaxId: sellerTaxId,
      invoiceNo: invoiceNo,
    );
  }

  /// 解析左＋右 QR（雙張合併：商家/明細來自右 QR）。
  /// 右 QR 無法解碼時明細留空、僅以左 QR 欄位建草稿（單 QR 舊式發票邊界，
  /// acceptance S3.2）。左 QR 無法辨識回 null。
  static TransactionDraft? parse(String leftQr, String rightQr) {
    final base = parseLeft(leftQr);
    if (base == null) return null;
    try {
      // 右 QR：deflate(raw)＋Base32 →「賣方名稱**品名**數量**單價**金額…」。
      final parts = InvoiceDetailCodec.decode(rightQr).split('**');
      final n = parts.length - 1;
      if (parts.length < 5 || n % 4 != 0) return _withLeftOnly(base);
      final merchant = parts[0].trim();
      final items = <InvoiceLineItem>[];
      for (var i = 1; i < parts.length; i += 4) {
        final quantity = int.tryParse(parts[i + 1]);
        final unitPrice = int.tryParse(parts[i + 2]);
        final amount = int.tryParse(parts[i + 3]);
        if (quantity == null || unitPrice == null || amount == null) {
          return _withLeftOnly(base); // 明細數值不可解析——視同無明細
        }
        items.add(InvoiceLineItem(
          name: parts[i].trim(),
          quantity: quantity,
          unitPrice: unitPrice,
          amount: amount,
        ));
      }
      return TransactionDraft(
        merchant: DraftField(merchant, 1.0),
        totalMinor: base.totalMinor,
        date: base.date,
        sellerTaxId: base.sellerTaxId,
        invoiceNo: base.invoiceNo,
        lineItems: items,
      );
    } on FormatException {
      return _withLeftOnly(base); // Base32/deflate 解碼失敗——明細留空
    }
  }

  /// 僅左 QR 欄位之草稿（商家/明細留空）。
  static TransactionDraft _withLeftOnly(TransactionDraft base) => TransactionDraft(
        merchant: const DraftField.none(),
        totalMinor: base.totalMinor,
        date: base.date,
        sellerTaxId: base.sellerTaxId,
        invoiceNo: base.invoiceNo,
      );

  // ---------------------------------------------------------------------------
  // 官方規格（財政部《電子發票證明聯一維及二維條碼規格說明》v1.9）。
  //
  // PM 2026-11-22「PWA/MAC/IPHONE 全平台掃描發票都失敗」**根因**：上述 SDD
  // §5.4 佈局（金額十進位 10 碼）**與官方規格不符**——官方左碼金額為十六進位
  // 8 碼，且 77 碼後常接 `:` 延伸區（品名:數量:單價…），實際長度多為 90–130
  // 字。真實發票因此全被「length==77＋十進位」規則拒絕（僅內部測資可過）。
  //
  // 官方左碼 77 碼固定區：[0,10)字軌號碼、[10,17)民國日期、[17,21)隨機碼、
  // [21,29)銷售額(hex)、[29,37)總計額(hex)、[37,45)買方統編、[45,53)賣方統編、
  // [53,77)加密驗證(AES+Base64)。77 之後＝以 `:` 區隔之延伸區（自行使用區
  // 10 碼、品目筆數、中文編碼參數、品名:數量:單價…，可溢出至右碼）。
  // 官方右碼：`**` 起始＋延續之品名:數量:單價…（規格 §貳二(二)）。
  // ---------------------------------------------------------------------------

  static final RegExp _base64Field = RegExp(r'^[A-Za-z0-9+/=]+$');

  /// 民國 YYYMMDD → DateTime（格式/存在性不合法回 null）。
  static DateTime? _parseRocDate(String s) {
    if (s.length != 7) return null;
    final y = int.tryParse(s.substring(0, 3));
    final m = int.tryParse(s.substring(3, 5));
    final d = int.tryParse(s.substring(5, 7));
    if (y == null || m == null || d == null) return null;
    if (y < 100 || m < 1 || m > 12 || d < 1 || d > 31) return null;
    final date = DateTime(y + 1911, m, d);
    if (date.year != y + 1911 || date.month != m || date.day != d) return null;
    return date;
  }

  /// 官方左碼驗證：≥77 字、延伸區必以 `:` 起始、兩個金額欄皆十六進位且
  /// 總計≥銷售額、加密驗證為 Base64 字元集、日期合法。
  ///
  /// 同時承擔「官方格式 vs 舊內部測資格式」判別（舊格式左碼的 [21,29) 為
  /// 十進位賣方統編、[29,37) 為十進位金額前 8 位——以 hex 解讀後
  /// 總計<銷售額 幾乎必不成立 → 落入舊格式路徑）與誤吞防護（其他 App
  /// 條碼不會同時通過全部檢查——不硬湊欄位、不產生錯誤交易）。
  static bool isValidOfficialLeft(String s) {
    if (s.length < 77) return false;
    if (s.length > 77 && s.codeUnitAt(77) != 0x3A /* ':' */) return false;
    final sales = int.tryParse(s.substring(21, 29), radix: 16);
    final total = int.tryParse(s.substring(29, 37), radix: 16);
    if (sales == null || total == null) return false;
    if (total < sales) return false;
    if (!_base64Field.hasMatch(s.substring(53, 77))) return false;
    return _parseRocDate(s.substring(10, 17)) != null;
  }

  /// 解析官方左碼（含 `:` 延伸區）＋可選官方右碼（`**` 起始）。
  ///
  /// 商家名稱**不在** QR 內（僅賣方統編）——確認頁手動補。明細限制：Big5
  /// （編碼參數 0）品名會亂碼（保留原字串供修正）；左右碼跨碼斷項（品項被
  /// 從中切開）可能產生殘缺明細——金額以左碼總計額為準，不受影響。
  static TransactionDraft? parseOfficial(String left, [String? right]) {
    if (!isValidOfficialLeft(left)) return null;
    final total = int.parse(left.substring(29, 37), radix: 16);
    final date = _parseRocDate(left.substring(10, 17))!;
    final items = <InvoiceLineItem>[
      ...(left.length > 77
          ? _parseItemFields(left.substring(78))
          : const <InvoiceLineItem>[]),
      ..._parseRightItems(right),
    ];
    final base = TransactionDraft(
      merchant: const DraftField.none(),
      totalMinor: DraftField(total, 1.0),
      date: DraftField(date, 1.0),
      sellerTaxId: left.substring(45, 53),
      invoiceNo: left.substring(0, 10),
    );
    if (items.isEmpty) return base;
    return TransactionDraft(
      merchant: base.merchant,
      totalMinor: base.totalMinor,
      date: base.date,
      sellerTaxId: base.sellerTaxId,
      invoiceNo: base.invoiceNo,
      lineItems: items,
    );
  }

  /// 自 `:` 分隔欄位流抽出「品名:數量:單價」三元組。
  ///
  /// 前導數值欄（自行使用區/品目筆數/編碼參數/跨碼斷項的數值尾）自動略過；
  /// 品名必為**非純數值**欄（規格品名含中文/英文）。
  static List<InvoiceLineItem> _parseItemFields(String joined) {
    final fields = [for (final f in joined.split(':')) f.trim()];
    final items = <InvoiceLineItem>[];
    for (var i = 0; i < fields.length; i++) {
      final name = fields[i];
      if (name.isEmpty || name == '**********' || int.tryParse(name) != null) {
        continue;
      }
      final qty = i + 1 < fields.length ? int.tryParse(fields[i + 1]) : null;
      final price = i + 2 < fields.length ? int.tryParse(fields[i + 2]) : null;
      if (qty == null || price == null) continue;
      items.add(InvoiceLineItem(
          name: name, quantity: qty, unitPrice: price, amount: qty * price));
      i += 2;
    }
    return items;
  }

  /// 官方右碼（`**` 起始）→ 明細。Base64 編碼參數（2）之右碼整體為一條
  /// Base64——先試 UTF-8 解碼再抽欄位；解不出仍以原文嘗試。
  static List<InvoiceLineItem> _parseRightItems(String? right) {
    if (right == null) return const [];
    final body = right.startsWith('**') ? right.substring(2) : right;
    var items = _parseItemFields(body);
    if (items.isEmpty && body.length >= 12 && _base64Field.hasMatch(body)) {
      try {
        items = _parseItemFields(utf8.decode(base64Decode(body),
            allowMalformed: true));
      } on FormatException {
        // 非法 Base64——維持空明細（左碼欄位仍有效）。
      }
    }
    return items;
  }
}
