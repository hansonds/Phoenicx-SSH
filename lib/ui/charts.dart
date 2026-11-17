import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';

class Series {
  final List<double> data;
  final List<Color> colors; // gradient along the line (left -> right)
  Series(this.data, Object color)
      : colors = color is List<Color> ? color : [color as Color, color];
  Color get main => colors.last;
}

/// Dependency-free live line chart with gradient lines, soft glow and a
/// filled area.
class LiveChart extends StatelessWidget {
  final List<Series> series;
  final double? maxY;
  final int capacity;
  final double height;

  /// Formats the value at the top of the chart (e.g. "100%" or "2.1 MB/s").
  final String Function(double top)? topLabel;
  const LiveChart(
      {super.key,
      required this.series,
      this.maxY,
      this.capacity = 90,
      this.height = 70,
      this.topLabel});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _ChartPainter(series, maxY, capacity, topLabel)),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<Series> series;
  final double? maxY;
  final int capacity;
  final String Function(double top)? topLabel;
  _ChartPainter(this.series, this.maxY, this.capacity, this.topLabel);

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      for (double x = 0; x < size.width; x += 8) {
        canvas.drawLine(Offset(x, y), Offset(x + 4, y), grid);
      }
    }
    var top = maxY ?? 0;
    if (maxY == null) {
      for (final s in series) {
        for (final v in s.data) {
          top = max(top, v);
        }
      }
      top = top <= 0 ? 1 : top * 1.15;
    }
    if (topLabel != null) {
      final tp = TextPainter(
        text: TextSpan(text: topLabel!(top), style: const TextStyle(fontSize: 9.5, color: PX.muted)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(size.width - tp.width - 2, 1));
    }
    final step = size.width / max(1, capacity - 1);
    final rect = Offset.zero & size;
    for (final s in series) {
      if (s.data.length < 2) continue;
      final start = capacity - s.data.length;
      final pts = <Offset>[
        for (var i = 0; i < s.data.length; i++)
          Offset((start + i) * step,
              size.height - (s.data[i] / top).clamp(0.0, 1.0) * (size.height - 2) - 1),
      ];
      // Smooth curve through the points.
      final path = Path()..moveTo(pts[0].dx, pts[0].dy);
      for (var i = 1; i < pts.length; i++) {
        final p0 = pts[i - 1], p1 = pts[i];
        final mx = (p0.dx + p1.dx) / 2;
        path.cubicTo(mx, p0.dy, mx, p1.dy, p1.dx, p1.dy);
      }
      final fill = Path.from(path)
        ..lineTo(pts.last.dx, size.height)
        ..lineTo(pts.first.dx, size.height)
        ..close();
      canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [s.main.withValues(alpha: 0.38), s.main.withValues(alpha: 0.0)],
          ).createShader(rect),
      );
      final lineShader = LinearGradient(colors: s.colors).createShader(rect);
      // Soft glow: a wide, faint stroke (much cheaper than a blur filter).
      canvas.drawPath(
        path,
        Paint()
          ..color = s.main.withValues(alpha: 0.18)
          ..strokeWidth = 6
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );
      canvas.drawPath(
        path,
        Paint()
          ..shader = lineShader
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
      // Glowing dot on the latest value.
      final last = pts.last;
      canvas.drawCircle(last, 5, Paint()..color = s.main.withValues(alpha: 0.3));
      canvas.drawCircle(last, 2.6, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}

/// Horizontal usage bar (kept for small lists).
class UsageBar extends StatelessWidget {
  final double percent;
  final Color color;
  const UsageBar({super.key, required this.percent, required this.color});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 6,
        child: Stack(children: [
          Container(color: Colors.white.withValues(alpha: 0.06)),
          FractionallySizedBox(
            widthFactor: (percent / 100).clamp(0.0, 1.0),
            child: Container(color: color),
          ),
        ]),
      ),
    );
  }
}

/// Circular gauge with a gradient arc and glow.
class RingGauge extends StatelessWidget {
  final double percent;
  final String label;
  final String? sub;
  final List<Color> colors;
  final double size;
  const RingGauge(
      {super.key, required this.percent, required this.label, this.sub, required this.colors, this.size = 86});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: size,
        height: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: percent.clamp(0, 100).toDouble()),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => CustomPaint(
            painter: _RingPainter(v, colors),
            child: Center(
              child: Text('${v.toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: size * 0.23, fontWeight: FontWeight.w800, height: 1)),
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      if (sub != null)
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Text(sub!, style: const TextStyle(fontSize: 10.5, color: PX.muted), textAlign: TextAlign.center),
        ),
    ]);
  }
}

class _RingPainter extends CustomPainter {
  final double percent;
  final List<Color> colors;
  _RingPainter(this.percent, this.colors);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.095;
    final rect = Rect.fromLTWH(stroke / 2 + 3, stroke / 2 + 3, size.width - stroke - 6, size.height - stroke - 6);
    canvas.drawArc(
        rect,
        0,
        2 * pi,
        false,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.07)
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke);
    final sweep = 2 * pi * (percent / 100).clamp(0.0, 1.0);
    if (sweep <= 0.001) return;
    final ringColors = [...colors, colors.first];
    final shader = ui.Gradient.sweep(
      rect.center,
      ringColors,
      [for (var i = 0; i < ringColors.length; i++) i / (ringColors.length - 1)],
      TileMode.clamp,
      -pi / 2,
      3 * pi / 2,
    );
    canvas.drawArc(
        rect,
        -pi / 2,
        sweep,
        false,
        Paint()
          ..color = colors.last.withValues(alpha: 0.2)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke + 7);
    canvas.drawArc(
        rect,
        -pi / 2,
        sweep,
        false,
        Paint()
          ..shader = shader
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.percent != percent || old.colors != colors;
}

/// A bar split into coloured parts (e.g. memory used / cache / free).
class StackedBar extends StatelessWidget {
  final List<(double, Color)> parts; // fractions 0..1
  const StackedBar({super.key, required this.parts});

  @override
  Widget build(BuildContext context) {
    final sum = parts.fold<double>(0, (a, b) => a + b.$1);
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        height: 9,
        child: Row(children: [
          for (final p in parts)
            if (p.$1 > 0) Expanded(flex: max(1, (p.$1 * 1000).round()), child: Container(color: p.$2)),
          if (sum < 1)
            Expanded(
              flex: max(1, ((1 - sum) * 1000).round()),
              child: Container(color: Colors.white.withValues(alpha: 0.06)),
            ),
        ]),
      ),
    );
  }
}
