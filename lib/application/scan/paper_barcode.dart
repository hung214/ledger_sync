/// 紙本電子發票**一維條碼**解析（官方規格 §壹：Code 39）。
///
/// 內容＝`*` + 年期別(5：民國年3+雙數月2) + 字軌號碼(10) + 隨機碼(4) + `*`
/// （官方範例：`*10404UZ176908720122*` → 104年3-4月、字軌 UZ17690872）。
/// 引擎回傳值可能含或不含前後 `*`／夾空白——一律剝除後比對。
///
/// PM 2026-11-22：紙本發票模式＝掃此條碼 → 自動帶**發票號碼**（2 碼英文
/// ＋8 數字）＋**年月提示**（期別首月 1 日）；金額/商家由使用者手動輸入。
({String invoiceNo, DateTime dateHint})? parsePaperBarcode(String raw) {
  var s = raw.trim().replaceAll(' ', '');
  while (s.startsWith('*')) {
    s = s.substring(1);
  }
  while (s.endsWith('*')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.length != 19) return null;
  final year = int.tryParse(s.substring(0, 3));
  final period = int.tryParse(s.substring(3, 5));
  final invoiceNo = s.substring(5, 15).toUpperCase();
  if (year == null || year < 100) return null;
  // 期別＝雙數月（期末月）：04 → 3-4 月。
  if (period == null || period < 2 || period > 12 || period.isOdd) return null;
  if (!RegExp(r'^[A-Z]{2}[0-9]{8}$').hasMatch(invoiceNo)) return null;
  return (
    invoiceNo: invoiceNo,
    dateHint: DateTime(year + 1911, period - 1, 1),
  );
}
