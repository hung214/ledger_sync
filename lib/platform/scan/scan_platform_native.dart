import 'dart:io';

/// 平台偵測 native（原生 App——macOS 測試機非 iOS；iPhone 原生掃描頁
/// 不走此流程）。
bool get isIOSDevice => Platform.isIOS;
