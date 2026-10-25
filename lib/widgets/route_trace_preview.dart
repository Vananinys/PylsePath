import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' as geo;

import '../models/workout_details.dart';

/// A local thumbnail needs no tile requests and preserves track gaps.
class RouteTracePreview extends StatelessWidget {
  const RouteTracePreview({
    super.key,
    required this.points,
    this.segmentStarts = const [],
  });
  final List<geo.LatLng> points;
  final List<int> segmentStarts;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      decoration: BoxDecoration(
        color: Colors.deepOrange.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: points.length < 2
          ? const Icon(Icons.route, color: Colors.deepOrange)
          : CustomPaint(
              painter: _TracePainter(points, segmentStarts),
              size: Size.infinite,
            ),
    ),
  );
}

class _TracePainter extends CustomPainter {
  _TracePainter(this.points, this.starts);
  final List<geo.LatLng> points;
  final List<int> starts;
  @override
  void paint(Canvas canvas, Size size) {
    if (size.shortestSide < 16) return;
    final cos = math
        .cos(points.first.latitude * math.pi / 180)
        .abs()
        .clamp(.01, 1);
    final baseLon = points.first.longitude;
    double x(geo.LatLng point) =>
        ((point.longitude - baseLon + 540) % 360 - 180) * cos;
    final minX = points.map(x).reduce(math.min),
        maxX = points.map(x).reduce(math.max);
    final minY = points.map((p) => p.latitude).reduce(math.min),
        maxY = points.map((p) => p.latitude).reduce(math.max);
    final scale = math.min(
      (size.width - 20) / math.max(maxX - minX, .000001),
      (size.height - 20) / math.max(maxY - minY, .000001),
    );
    Offset project(geo.LatLng point) => Offset(
      size.width / 2 + (x(point) - (minX + maxX) / 2) * scale,
      size.height / 2 - (point.latitude - (minY + maxY) / 2) * scale,
    );
    final pen = Paint()
      ..color = Colors.deepOrange
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final segment in WorkoutDetails.splitTrack(points, starts)) {
      final path = Path();
      // At most 2400 vertices per thumbnail; retain the actual segment end.
      final stride = (segment.length / 2400).ceil().clamp(1, 1000000);
      for (var i = 0; i < segment.length; i += stride) {
        final p = project(segment[i]);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      if (segment.isNotEmpty) {
        final p = project(segment.last);
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, pen);
    }
    canvas.drawCircle(project(points.first), 3, Paint()..color = Colors.green);
    canvas.drawCircle(
      project(points.last),
      3,
      Paint()..color = Colors.deepOrange,
    );
  }

  @override
  bool shouldRepaint(_TracePainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.starts != starts;
}
