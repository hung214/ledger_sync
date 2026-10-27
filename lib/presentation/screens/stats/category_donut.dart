import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../../application/reports/report_service.dart';

/// 統計色板（**固定色**；PM 2026-10-26——對齊 11-stats 雛型）。
///
/// 不用 ColorScheme 衍生的 container 色（過淡、可讀性差）；索引在
/// 甜甜圈扇區與圖例色點間**一致**（同一 `index` → 同色）。
const List<Color> statsPalette = [
  Color(0xFF0B7A75), // teal（餐飲）
  Color(0xFFF5C86B), // amber
  Color(0xFF6D4FC4), // purple
  Color(0xFFD64545), // red
  Color(0xFF1D6FD1), // blue
  Color(0xFF3B9B46), // green
  Color(0xFFEC4899), // pink
  Color(0xFFF97316), // orange
];

/// 分類占比甜甜圈（PM 2026-10-26 改版）。
///
/// - 百分比**不壓在扇區上**——改以**引線**標註於圈外（扇區中線 → 外緣 → 折線 → 文字），
///   同側標籤自動上下推開避免重疊。
/// - 圓心＝合計（千分位）。
/// - 扇區色＝[statsPalette]（與圖例同索引同色）。
class CategoryDonut extends StatelessWidget {
  const CategoryDonut({
    super.key,
    required this.shares,
    required this.totalMinor,
    this.height = 210,
    this.centerLabel = '合計',
    this.centerText,
    this.colors,
  });

  /// 占比資料（**已降冪、僅 >0**）；索引對應 [statsPalette]。
  final List<CategoryShare> shares;
  final int totalMinor;
  final double height;

  /// 圓心標籤／數值（PM 2026-10-27：淨額檢視＝中心顯示「淨額」與其值）。
  final String centerLabel;
  final String? centerText;

  /// 扇區色覆寫（未提供＝[statsPalette] 依索引；PM 2026-10-27：淨額檢視傳
  /// 收入綠／支出紅，語意清楚且易辨）。
  final List<Color>? colors;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            key: const Key('stats-donut'),
            size: Size.infinite,
            painter: _DonutPainter(
              shares: shares,
              totalMinor: totalMinor,
              colors: colors,
              labelStyle: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
              lineColor: scheme.outlineVariant,
            ),
          ),
          // 中心合計（與頁面文字同值——圖表輔助呈現）。
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(centerLabel,
                  style: Theme.of(context).textTheme.labelSmall),
              Text(centerText ?? NumberFormat('#,###').format(totalMinor),
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.shares,
    required this.totalMinor,
    required this.labelStyle,
    required this.lineColor,
    this.colors,
  });

  final List<CategoryShare> shares;
  final int totalMinor;
  final TextStyle labelStyle;
  final Color lineColor;
  final List<Color>? colors;

  Color _colorAt(int i) =>
      colors != null && i < colors!.length
          ? colors![i]
          : statsPalette[i % statsPalette.length];

  /// 起始角＝正上方（-90°），順時針。
  static const double _startDeg = -90;

  @override
  void paint(Canvas canvas, Size size) {
    if (shares.isEmpty || totalMinor <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    // 外緣半徑（預留標籤空間）；環厚＝34%。
    final outerR = math.min(size.width, size.height) / 2 - 34;
    if (outerR <= 8) return;
    final thickness = outerR * 0.34;
    final radius = outerR - thickness / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // 扇區（含 0.8° 間隙）。
    var start = _startDeg;
    final sweeps = <double>[];
    for (final (i, s) in shares.indexed) {
      final sweep = s.amountMinor / totalMinor * 360;
      sweeps.add(sweep);
      canvas.drawArc(
        rect,
        start * math.pi / 180,
        math.max(sweep - 0.8, 0.4) * math.pi / 180,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness
          ..color = _colorAt(i),
      );
      start += sweep;
    }

    // 引線＋百分比（圈外；同側上下推開）。
    final left = <(double, int)>[];
    final right = <(double, int)>[];
    var a = _startDeg;
    for (var i = 0; i < shares.length; i++) {
      final mid = a + sweeps[i] / 2;
      final rad = mid * math.pi / 180;
      final y = center.dy + math.sin(rad) * (outerR + 16);
      (math.cos(rad) < 0 ? left : right).add((y, i));
      a += sweeps[i];
    }
    for (final group in [left, right]) {
      group.sort((x, y) => x.$1.compareTo(y.$1));
      for (var i = 1; i < group.length; i++) {
        // 標籤最小間距 15px。
        if (group[i].$1 - group[i - 1].$1 < 15) {
          group[i] = (group[i - 1].$1 + 15, group[i].$2);
        }
      }
    }

    void drawLabel(int i, double labelY, bool isLeft) {
      final mid = _midAngleOf(i);
      final rad = mid * math.pi / 180;
      final p1 = center + Offset(math.cos(rad) * outerR, math.sin(rad) * outerR);
      final p2 = center +
          Offset(math.cos(rad) * (outerR + 10),
              math.sin(rad) * (outerR + 10));
      final elbowX = isLeft
          ? center.dx - outerR - 22
          : center.dx + outerR + 22;
      final p3 = Offset(elbowX, labelY);
      final paint = Paint()
        ..color = _colorAt(i)
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke;
      canvas.drawLine(p1, p2, paint);
      canvas.drawLine(p2, p3, paint);

      final tp = TextPainter(
        text: TextSpan(text: '${shares[i].percentText}%', style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = isLeft ? p3.dx - tp.width - 4 : p3.dx + 4;
      tp.paint(canvas, Offset(dx, labelY - tp.height / 2));
    }

    for (final (y, i) in left) {
      if (y > 0 && y < size.height) drawLabel(i, y, true);
    }
    for (final (y, i) in right) {
      if (y > 0 && y < size.height) drawLabel(i, y, false);
    }
  }

  double _midAngleOf(int index) {
    var a = _startDeg;
    for (var i = 0; i < shares.length; i++) {
      final sweep = shares[i].amountMinor / totalMinor * 360;
      if (i == index) return a + sweep / 2;
      a += sweep;
    }
    return _startDeg;
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.colors != colors ||
      old.shares != shares ||
      old.totalMinor != totalMinor ||
      old.labelStyle != labelStyle ||
      old.lineColor != lineColor;
}
