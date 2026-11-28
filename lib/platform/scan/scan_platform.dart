/// 掃描平台偵測（條件匯出——同 camera_stream 慣例）。
/// iOS＝Apple BarcodeDetector 的繁中限制（T93——PM 決策：備註只放發票號）。
library;

export 'scan_platform_stub.dart'
    if (dart.library.io) 'scan_platform_native.dart'
    if (dart.library.js_interop) 'scan_platform_web.dart';
