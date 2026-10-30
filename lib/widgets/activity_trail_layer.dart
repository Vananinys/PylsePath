import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../data/trail_appearance.dart';
import '../models/activity_type.dart';
import '../models/live_trail_style.dart';

class TrailStamp {
  const TrailStamp(this.position, this.angle, this.alternate);
  final Offset position;
  final double angle;
  final bool alternate;
}

/// Bounded screen-space decoration. Gaps reset phase; no geographic data changes.
List<TrailStamp> sampleTrail(
  List<List<Offset>> segments,
  double spacing,
  Rect viewport, {
  int limit = 600,
  double phaseOffset = 0,
}) {
  if (!spacing.isFinite || spacing < 1 || limit <= 0) return const [];
  final result = <TrailStamp>[];
  for (final segment in segments) {
    var walked = identical(segment, segments.first) ? phaseOffset : 0.0;
    for (var i = 1; i < segment.length; i++) {
      final a = segment[i - 1], b = segment[i], d = b - a;
      if (!a.dx.isFinite ||
          !a.dy.isFinite ||
          !b.dx.isFinite ||
          !b.dy.isFinite) {
        walked = 0;
        continue;
      }
      final length = d.distance;
      if (!length.isFinite) {
        walked = 0;
        continue;
      }
      if (length < .01) continue;
      var lo = 0.0, hi = 1.0;
      bool clip(double origin, double delta, double min, double max) {
        if (delta.abs() < 1e-12) return origin >= min && origin <= max;
        final x = (min - origin) / delta, y = (max - origin) / delta;
        lo = math.max(lo, math.min(x, y));
        hi = math.min(hi, math.max(x, y));
        return lo <= hi;
      }

      if (clip(a.dx, d.dx, viewport.left, viewport.right) &&
          clip(a.dy, d.dy, viewport.top, viewport.bottom)) {
        final phase = (spacing / 2 - walked % spacing + spacing) % spacing;
        var distance =
            phase +
            math.max(0, ((lo * length - phase) / spacing).ceil()) * spacing;
        for (; distance <= hi * length; distance += spacing) {
          if (result.length >= limit) return result;
          result.add(
            TrailStamp(
              a + d * (distance / length),
              math.atan2(d.dy, d.dx),
              ((walked + distance) / spacing).floor().isOdd,
            ),
          );
        }
      }
      walked += length;
    }
  }
  return result;
}

class ActivityTrailLayer extends StatefulWidget {
  const ActivityTrailLayer({
    super.key,
    required this.segments,
    required this.activity,
    this.transport,
    this.recorded = false,
    this.baseColor = Colors.deepOrange,
    this.baseWidth = 4,
    this.live = false,
    this.idle = false,
    this.phaseOffset = 0,
    this.liveAppearance,
  });
  final List<List<LatLng>> segments;
  final ActivityType activity;
  final String? transport;
  final bool recorded;
  final Color baseColor;
  final double baseWidth;
  final bool live, idle;
  final double phaseOffset;
  final LiveTrailStyle? liveAppearance;
  @override
  State<ActivityTrailLayer> createState() => _ActivityTrailLayerState();
}

class _ActivityTrailLayerState extends State<ActivityTrailLayer> {
  List<List<LatLng>>? _source;
  List<List<Offset>> _world = [];
  double? _zoom;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: TrailAppearance.instance,
    builder: (context, _) {
      final prefs = TrailAppearance.instance, camera = MapCamera.of(context);
      final personal = widget.liveAppearance ?? const LiveTrailStyle();
      final enabled = widget.live
          ? (widget.idle ? prefs.onIdle : prefs.onFriends) && personal.enabled
          : widget.recorded
          ? prefs.onRecording
          : prefs.onRoutes;
      final style = prefs.effective(
        widget.activity,
        transport: widget.transport,
        pattern: widget.live ? personal.style : null,
      );
      if (widget.live && !enabled) return const SizedBox.shrink();
      final decorated =
          enabled &&
          (style != TrailStyle.line ||
              (widget.live && personal.effect != MotionEffect.none)) &&
          camera.zoom >= 12;
      if (decorated && (_source != widget.segments || _zoom != 16)) {
        _source = widget.segments;
        _zoom = 16;
        _world = [
          for (final segment in widget.segments)
            [
              for (final p in segment)
                (() {
                  final q = camera.project(p, 16);
                  return Offset(q.x, q.y);
                })(),
            ],
        ];
      }
      final origin = Offset(camera.pixelOrigin.x, camera.pixelOrigin.y);
      return IgnorePointer(
        child: Stack(
          children: [
            if (!decorated ||
                (prefs.guide &&
                    style == TrailStyle.line &&
                    (!widget.live || personal.effect == MotionEffect.none)))
              PolylineLayer(
                polylines: [
                  for (final segment in widget.segments)
                    Polyline(
                      points: segment,
                      color: widget.live
                          ? TrailAppearance.colors[personal.colorIndex]
                                .withValues(alpha: personal.opacity)
                          : enabled
                          ? prefs.color.withValues(
                              alpha: decorated
                                  ? prefs.opacity * .28
                                  : prefs.opacity,
                            )
                          : widget.baseColor,
                      strokeWidth: widget.baseWidth,
                    ),
                ],
              ),
            if (decorated)
              MobileLayerTransformer(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: TrailPainter(
                    _world,
                    style,
                    (widget.live
                            ? TrailAppearance.colors[personal.colorIndex]
                            : prefs.color)
                        .withValues(
                          alpha: widget.live ? personal.opacity : prefs.opacity,
                        ),
                    widget.live ? personal.size : prefs.size,
                    widget.live ? personal.spacing : prefs.spacing,
                    origin: origin,
                    scale: math.pow(2, camera.zoom - 16).toDouble(),
                    phaseOffset: widget.phaseOffset,
                    effect: widget.live ? personal.effect : MotionEffect.none,
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class TrailPainter extends CustomPainter {
  TrailPainter(
    this.segments,
    this.style,
    this.color,
    this.markerSize,
    this.spacing, {
    this.origin = Offset.zero,
    this.scale = 1,
    this.phaseOffset = 0,
    this.effect = MotionEffect.none,
  });
  final MotionEffect effect;
  final List<List<Offset>> segments;
  final Offset origin;
  final double scale;
  final double phaseOffset;
  final TrailStyle style;
  final Color color;
  final double markerSize, spacing;
  @override
  void paint(Canvas canvas, Size size) {
    if (style == TrailStyle.line && effect == MotionEffect.none) {
      final pen = Paint()
        ..color = color
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke;
      for (final segment in segments) {
        if (segment.isEmpty) continue;
        final path = Path()..moveTo(segment.first.dx, segment.first.dy);
        for (final point in segment.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, pen);
      }
      return;
    }
    final stamps = sampleTrail(
      segments,
      spacing,
      Rect.fromLTWH(
        origin.dx / scale,
        origin.dy / scale,
        size.width / scale,
        size.height / scale,
      ).inflate(markerSize * 2 / scale),
      phaseOffset: phaseOffset,
    );
    canvas.save();
    canvas.translate(-origin.dx, -origin.dy);
    final fill = Paint()..color = color;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final stamp in stamps) {
      canvas.save();
      canvas.translate(stamp.position.dx * scale, stamp.position.dy * scale);
      canvas.rotate(stamp.angle + math.pi / 2);
      canvas.scale(markerSize / 12 * math.min(1.0, scale));
      if (effect != MotionEffect.none) {
        final palette = effect == MotionEffect.confetti
            ? [Colors.cyan, Colors.pink, Colors.amber, Colors.greenAccent]
            : effect == MotionEffect.ember
            ? [Colors.orange, Colors.redAccent, Colors.amber, color]
            : [color, Color.lerp(color, Colors.white, .55)!, color, color];
        for (var j = 0; j < 4; j++) {
          final pen = Paint()..color = palette[j].withValues(alpha: color.a);
          final x = (j.isEven ? -1.0 : 1.0) * (3 + j);
          final y = (j - 1.5) * 4;
          if (effect == MotionEffect.pixel) {
            canvas.drawRect(
              Rect.fromCenter(center: Offset(x, y), width: 3, height: 3),
              pen,
            );
          } else if (effect == MotionEffect.orbit) {
            canvas.drawPath(
              Path()
                ..moveTo(x, y - 3)
                ..lineTo(x + 1, y - 1)
                ..lineTo(x + 3, y)
                ..lineTo(x + 1, y + 1)
                ..lineTo(x, y + 3)
                ..lineTo(x - 1, y + 1)
                ..lineTo(x - 3, y)
                ..lineTo(x - 1, y - 1)
                ..close(),
              pen,
            );
          } else if (effect == MotionEffect.bloom) {
            canvas.drawOval(
              Rect.fromCenter(center: Offset(x, y), width: 3, height: 6),
              pen,
            );
          } else {
            canvas.drawCircle(Offset(x, y), 1.5 + j * .3, pen);
          }
        }
        canvas.restore();
        continue;
      }
      switch (style) {
        case TrailStyle.footprints:
        case TrailStyle.boots:
        case TrailStyle.running:
        case TrailStyle.nordic:
          final side = stamp.alternate ? 1.0 : -1.0;
          canvas.translate(side * 3, 0);
          canvas.rotate(side * .12);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(-2.2, -5.5, 4.4, 7),
              const Radius.circular(2.2),
            ),
            fill,
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(-1.8, 2, 3.6, 3.2),
              const Radius.circular(1.2),
            ),
            fill,
          );
          if (style == TrailStyle.boots)
            for (var y = -3; y < 2; y += 2)
              canvas.drawLine(
                Offset(-3, y.toDouble()),
                Offset(3, y.toDouble()),
                line,
              );
          if (style == TrailStyle.running)
            canvas.drawLine(const Offset(-1, 7), const Offset(1, 9), line);
          if (style == TrailStyle.nordic)
            canvas.drawCircle(Offset(side * 5, 2), 1.3, fill);
        case TrailStyle.mountain:
        case TrailStyle.gravel:
          for (var y = -4; y <= 4; y += 4) {
            final path = Path()
              ..moveTo(-4, y - 2.0)
              ..lineTo(0, y + 1.0)
              ..lineTo(4, y - 2.0);
            canvas.drawPath(path, line);
            if (style == TrailStyle.gravel)
              canvas.drawCircle(Offset(0, y + 2.0), .8, fill);
          }
        case TrailStyle.car:
          for (final x in [-5.0, 5.0]) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromLTWH(x - 1.5, -6, 3, 12),
                const Radius.circular(.8),
              ),
              fill,
            );
          }
        case TrailStyle.road:
          canvas.drawLine(const Offset(-1, -6), const Offset(-1, 6), line);
          canvas.drawLine(const Offset(1, -6), const Offset(1, 6), line);
        case TrailStyle.bicycle:
          canvas.drawLine(const Offset(0, -6), const Offset(0, 6), line);
          canvas.drawLine(const Offset(-3, -3), const Offset(3, 0), line);
          canvas.drawLine(const Offset(-3, 2), const Offset(3, 5), line);
        case TrailStyle.scooter:
          canvas.drawCircle(const Offset(0, -4), 2, fill);
          canvas.drawCircle(const Offset(0, 4), 2, fill);
          canvas.drawLine(const Offset(0, -2), const Offset(0, 2), line);
        case TrailStyle.dots:
          canvas.drawCircle(Offset.zero, 2.4, fill);
        case TrailStyle.arrows:
        case TrailStyle.automatic:
          canvas.drawPath(
            Path()
              ..moveTo(-4, 3)
              ..lineTo(0, -4)
              ..lineTo(4, 3),
            line,
          );
        case TrailStyle.line:
          break;
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(TrailPainter old) =>
      old.segments != segments ||
      old.origin != origin ||
      old.scale != scale ||
      old.phaseOffset != phaseOffset ||
      old.style != style ||
      old.effect != effect ||
      old.color != color ||
      old.markerSize != markerSize ||
      old.spacing != spacing;
}

class TrailStylePreview extends StatelessWidget {
  const TrailStylePreview({
    super.key,
    required this.appearance,
    required this.activity,
    this.transport,
    this.effect = MotionEffect.none,
  });
  final MotionEffect effect;
  final TrailAppearance appearance;
  final ActivityType activity;
  final String? transport;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 130,
    child: LayoutBuilder(
      builder: (context, box) {
        final points = [
          Offset(15, 105),
          Offset(box.maxWidth * .3, 85),
          Offset(box.maxWidth * .52, 25),
          Offset(box.maxWidth * .75, 55),
          Offset(box.maxWidth - 15, 25),
        ];
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: CustomPaint(
            painter: TrailPainter(
              [points],
              appearance.effective(activity, transport: transport),
              appearance.color.withValues(alpha: appearance.opacity),
              appearance.size,
              appearance.spacing,
              effect: effect,
            ),
            size: Size.infinite,
          ),
        );
      },
    ),
  );
}
