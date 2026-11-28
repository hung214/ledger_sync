import 'dart:math' as math;
import 'dart:ui';

/// **T88 偵測框座標映射**（PM 2026-11-25「掃到條碼要有框」）：video 像素
/// 座標 → 預覽顯示座標（object-fit: cover：等比放大至貼滿→置中→超出
/// 裁切）——與 camera_stream_web 的 video CSS（100%×100%＋cover）同步。
/// 超出顯示區（cover 裁切區）的框允許負座標/超界——由 Stack 裁切。
Rect mapVideoRectToDisplay(Rect box, Size video, Size display) {
  if (video.isEmpty || display.isEmpty) return Rect.zero;
  final scale = math.max(
    display.width / video.width,
    display.height / video.height,
  );
  final dx = (display.width - video.width * scale) / 2;
  final dy = (display.height - video.height * scale) / 2;
  return Rect.fromLTWH(
    box.left * scale + dx,
    box.top * scale + dy,
    box.width * scale,
    box.height * scale,
  );
}

/// **T91 顯示座標 → video 像素座標**（cover 映射的**反向**）：
/// 取景框/ROI 在畫面上的位置 → 對應的 video 子區（裁切偵測與 ROI 解碼用）。
///
/// 與 [mapVideoRectToDisplay] 完全互逆（同一 cover 幾何：等比放大至貼滿
/// → 置中 → 超出裁切）；結果可能超出 video 邊界（顯示區含黑邊時）——
/// 呼叫端用前先夾限至 video 範圍。
/// 顯示座標點 → video **正規化**座標（cover 映射逆運算——點選對焦用，
/// T93）。出框 → 夾限 0~1。
Offset mapDisplayPointToVideoNormalized(Offset p, Size video, Size display) {
  if (video.isEmpty || display.isEmpty) return Offset.zero;
  final scale = math.max(
    display.width / video.width,
    display.height / video.height,
  );
  final dx = (display.width - video.width * scale) / 2;
  final dy = (display.height - video.height * scale) / 2;
  final vx = (p.dx - dx) / scale;
  final vy = (p.dy - dy) / scale;
  return Offset(
    (vx / video.width).clamp(0.0, 1.0),
    (vy / video.height).clamp(0.0, 1.0),
  );
}

Rect mapDisplayRectToVideo(Rect r, Size video, Size display) {
  if (video.isEmpty || display.isEmpty) return Rect.zero;
  final scale = math.max(
    display.width / video.width,
    display.height / video.height,
  );
  final dx = (display.width - video.width * scale) / 2;
  final dy = (display.height - video.height * scale) / 2;
  return Rect.fromLTWH(
    (r.left - dx) / scale,
    (r.top - dy) / scale,
    r.width / scale,
    r.height / scale,
  );
}
