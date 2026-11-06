import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../utils/drawn_route_geometry.dart';

class RouteDrawingLayer extends StatefulWidget {
  const RouteDrawingLayer({super.key, required this.onStroke, this.onLimit});
  final void Function(List<LatLng> raw, List<LatLng> smooth) onStroke;
  final VoidCallback? onLimit;
  @override
  State<RouteDrawingLayer> createState() => _RouteDrawingLayerState();
}

class _RouteDrawingLayerState extends State<RouteDrawingLayer> {
  final _points = <Offset>[];
  MapCamera? _camera;
  bool _overflow = false;
  bool _cancelled = false;
  final _pointers = <int>{};
  void _add(Offset point) {
    if (_cancelled) return;
    if (_points.length >= 3000) {
      _overflow = true;
      return;
    }
    if (_points.isEmpty || (point - _points.last).distance >= 3) {
      setState(() => _points.add(point));
    }
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    // Own this pointer sequence before FlutterMap's drag/scale/long-press team.
    // Raw samples also preserve slow strokes and the initial contact position.
    gestures: {
      EagerGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
            () => EagerGestureRecognizer(),
            (_) {},
          ),
    },
    behavior: HitTestBehavior.opaque,
    child: Listener(
      key: const ValueKey('route-drawing-canvas'),
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _pointers.add(event.pointer);
        if (_pointers.length > 1) {
          _cancelled = true;
          setState(_points.clear);
          return;
        }
        _cancelled = false;
        _camera = MapCamera.of(context);
        _points.clear();
        _overflow = false;
        _add(event.localPosition);
      },
      onPointerMove: (event) {
        if (_pointers.length == 1) _add(event.localPosition);
      },
      onPointerCancel: (event) {
        _pointers.remove(event.pointer);
        _cancelled = true;
        setState(_points.clear);
      },
      onPointerUp: (event) {
        _pointers.remove(event.pointer);
        if (_pointers.isNotEmpty) return;
        if (!_cancelled) _add(event.localPosition);
        final camera = _camera;
        if (_cancelled) {
          _points.clear();
        } else if (_overflow) {
          widget.onLimit?.call();
        } else if (camera != null && _points.length >= 2) {
          List<LatLng> convert(List<Offset> points) => [
            for (final p in points)
              camera.pointToLatLng(math.Point(p.dx, p.dy)),
          ];
          widget.onStroke(
            convert(_points),
            convert(smoothDrawnStroke(_points)),
          );
        }
        if (mounted) setState(_points.clear);
      },
      child: CustomPaint(
        size: Size.infinite,
        painter: _GesturePainter(
          List.of(_points),
          Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );
}

class _GesturePainter extends CustomPainter {
  const _GesturePainter(this.points, this.color);
  final List<Offset> points;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_GesturePainter old) =>
      old.points != points || old.color != color;
}
