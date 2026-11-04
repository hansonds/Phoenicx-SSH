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
  const LiveChart(
      {super.key, required this.series, this.maxY, this.capacity = 90, this.height = 70});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _ChartPainter(series, maxY, capacity),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<Series> series;
  final double? maxY;
  final int capacity;
  _ChartPainter(this.series, this.maxY, this.capacity);

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
