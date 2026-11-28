import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// 掃描成功震動（參考文件建議；Android Chrome 支援，iOS Safari 不支援
/// ＝靜默失敗無妨）。
void vibrateSuccess() {
  try {
    web.window.navigator.vibrate(100.toJS);
  } catch (_) {}
}
