import 'dart:math' as math;
import 'dart:ui';

/// **T88 偵測框座標映射**（PM 2026-11-25「掃到條碼要有框」）：video 像素
/// 座標 → 預覽顯示座標（object-fit: cover：等比放大至貼滿→置中→超出
/// 裁切）——與 camera_stream_web 的 video CSS（100%×100%＋cover）同步。
/// 超出顯示區（cover 裁切區）的框允許負座標/超界——由 Stack 裁切。
Rect mapVideoRectToDisplay(Rect box, Size video, Size display) {
  if (video.isEmpty || display.isEmpty) return Rect.zero;
  final scale =
      math.max(display.width / video.width, display.height / video.height);
  final dx = (display.width - video.width * scale) / 2;
  final dy = (display.height - video.height * scale) / 2;
  return Rect.fromLTWH(
    box.left * scale + dx,
    box.top * scale + dy,
    box.width * scale,
    box.height * scale,
  );
}
