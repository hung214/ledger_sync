/// 掃描觸覺回饋（平台分流——條件匯出；同 camera_stream 慣例）。
library;

export 'scan_haptics_stub.dart'
    if (dart.library.io) 'scan_haptics_native.dart'
    if (dart.library.js_interop) 'scan_haptics_web.dart';
