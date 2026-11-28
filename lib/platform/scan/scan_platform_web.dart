import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:web/web.dart' as web;

/// 平台偵測 web（userAgent——T89c 同款判斷）。
/// iPhone/iPad＝Apple BarcodeDetector（Byte-mode 中文解碼不回位元組）。
bool get isIOSDevice {
  if (!kIsWeb) return false;
  final ua = web.window.navigator.userAgent.toLowerCase();
  return ua.contains('iphone') || ua.contains('ipad');
}
