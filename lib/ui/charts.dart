import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';

class Series {
  final List<double> data;
  final Color color;
  const Series(this.data, this.color);
}

/// Tiny dependency-free live line chart.
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
      child: CustomPaint(
        painter: _ChartPainter(series, maxY, capacity, topLabel),
      ),
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
      ..color = PX.line
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
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
    for (final s in series) {
      if (s.data.length < 2) continue;
      final start = capacity - s.data.length;
      final path = Path();
      for (var i = 0; i < s.data.length; i++) {
        final x = (start + i) * step;
        final y = size.height - (s.data[i] / top).clamp(0.0, 1.0) * size.height;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      final fill = Path.from(path)
        ..lineTo((start + s.data.length - 1) * step, size.height)
        ..lineTo(start * step, size.height)
        ..close();
      canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [s.color.withValues(alpha: 0.35), s.color.withValues(alpha: 0.02)],
          ).createShader(Offset.zero & size),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = s.color
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}

/// Horizontal usage bar.
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
          Container(color: PX.surface2),
          FractionallySizedBox(
            widthFactor: (percent / 100).clamp(0.0, 1.0),
            child: Container(color: color),
          ),
        ]),
      ),
    );
  }
}

/// Circular percentage gauge.
class RingGauge extends StatelessWidget {
  final double percent;
  final String label;
  final String? sub;
  final Color color;
  final double size;
  const RingGauge(
      {super.key, required this.percent, required this.label, this.sub, required this.color, this.size = 74});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter(percent, color),
          child: Center(
            child: Text('${percent.toStringAsFixed(0)}%',
                style: TextStyle(fontSize: size * 0.22, fontWeight: FontWeight.w700)),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      if (sub != null)
        Text(sub!, style: const TextStyle(fontSize: 10.5, color: PX.muted), textAlign: TextAlign.center),
    ]);
  }
}

class _RingPainter extends CustomPainter {
  final double percent;
  final Color color;
  _RingPainter(this.percent, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.1;
    final rect = Rect.fromLTWH(stroke / 2, stroke / 2, size.width - stroke, size.height - stroke);
    canvas.drawArc(
        rect,
        0,
        2 * pi,
        false,
        Paint()
          ..color = PX.surface2
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke);
    final c = percent >= 90 ? PX.red : (percent >= 75 ? PX.yellow : color);
    canvas.drawArc(
        rect,
        -pi / 2,
        2 * pi * (percent / 100).clamp(0.0, 1.0),
        false,
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.percent != percent || old.color != color;
}

/// A bar split into coloured parts (e.g. memory used / cache / free).
class StackedBar extends StatelessWidget {
  final List<(double, Color)> parts; // fractions 0..1
  const StackedBar({super.key, required this.parts});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Row(children: [
          for (final p in parts)
            if (p.$1 > 0) Expanded(flex: max(1, (p.$1 * 1000).round()), child: Container(color: p.$2)),
          if (parts.fold<double>(0, (a, b) => a + b.$1) < 1)
            Expanded(
              flex: max(1, ((1 - parts.fold<double>(0, (a, b) => a + b.$1)) * 1000).round()),
              child: Container(color: PX.surface2),
            ),
        ]),
      ),
    );
  }
}
