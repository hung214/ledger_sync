import 'package:web/web.dart' as web;

/// 讀取並清除 `ls_pending_scan`（相機整頁重載後 → AppRoot 導回掃描頁）。
/// 無旗標/例外 → null。
String? consumePendingScanFlag() {
  try {
    final v = web.window.sessionStorage.getItem('ls_pending_scan');
    if (v == null) return null;
    web.window.sessionStorage.removeItem('ls_pending_scan');
    return v;
  } catch (_) {
    return null;
  }
}
