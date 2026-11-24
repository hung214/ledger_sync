/// Native 平台 stub（html5qrcode_scanner.dart 條件匯出——native 編譯安全；
/// PWA 掃描頁在 VM 測試載入此版——行為與「JS 未載」一致）。
library;

import 'html5qrcode_scanner.dart';

class Html5QrScannerImpl implements Html5QrScanner {
  const Html5QrScannerImpl();

  @override
  bool get jsLoaded => false;

  @override
  Future<void> start({
    required String elementId,
    required void Function(String text) onDecoded,
  }) async {
    throw UnsupportedError('Html5QrScanner：web 專用');
  }

  @override
  Future<void> stop() async {}

  @override
  bool get torchSupported => false;

  @override
  bool get torchOn => false;

  @override
  void registerReaderView(String viewType) {}

  @override
  Future<void> toggleTorch() async {}

  @override
  TwEinInvoice? parseInvoice(List<String> texts) => null;
}

final Html5QrScanner html5QrScanner = const Html5QrScannerImpl();
