/// 發票 QR 文字 Big5 解碼（平台分流——條件匯出；同 camera_stream 慣例）。
/// 背景：7-11 等通路 POS 以 **Big5** 編碼品目（官方規格＝UTF-8）——
/// 偵測器解出的文字須以原始位元組重解（T93，fixture IMG_2073 重現）。
library;

export 'invoice_big5_stub.dart'
    if (dart.library.io) 'invoice_big5_native.dart'
    if (dart.library.js_interop) 'invoice_big5_web.dart';
