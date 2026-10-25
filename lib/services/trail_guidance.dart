import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/route_step.dart';
import '../utils/geo_utils.dart';
import '../models/workout_details.dart';

/// Geometric guidance for a saved track. No road legality or street names
/// are inferred. Gaps must be split before calling this method.
class TrailGuidance {
  static List<RouteStep> segmentedSteps(List<LatLng> points, List<int> starts) {
    final segments = WorkoutDetails.splitTrack(
      points,
      starts,
    ).where((s) => s.length >= 2).toList();
    final result = <RouteStep>[];
    var offset = 0.0;
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      for (final step in steps(segment)) {
        result.add(
          RouteStep(
            instruction: step.icon == Icons.flag && i < segments.length - 1
                ? 'Конец участка · дальше разрыв трека'
                : step.instruction,
            streetName: '',
            icon: step.icon,
            location: step.location,
            distance: step.distance,
            routeOffsetMeters: offset + step.routeOffsetMeters,
          ),
        );
      }
      offset += length(segment);
    }
    return result;
  }

  static double length(List<LatLng> points) {
    var meters = 0.0;
    for (var i = 1; i < points.length; i++) {
      meters += GeoUtils.distanceBetween(points[i - 1], points[i]);
    }
    return meters;
  }

  static List<RouteStep> steps(List<LatLng> points) {
    if (points.length < 2) return [];
    final anchors = <LatLng>[points.first];
    final offsets = <double>[0];
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += GeoUtils.distanceBetween(points[i - 1], points[i]);
      if (GeoUtils.distanceBetween(anchors.last, points[i]) >= 25 ||
          i == points.length - 1) {
        anchors.add(points[i]);
        offsets.add(total);
      }
    }
    final result = <RouteStep>[];
    const distance = Distance();
    var lastTurn = -50.0;
    for (var i = 1; i < anchors.length - 1; i++) {
      final before = distance.bearing(anchors[i - 1], anchors[i]);
      final after = distance.bearing(anchors[i], anchors[i + 1]);
      final delta = (after - before + 540) % 360 - 180;
      if (delta.abs() < 40 || offsets[i] - lastTurn < 35) continue;
      lastTurn = offsets[i];
      result.add(
        RouteStep(
          instruction: delta > 0 ? 'По треку направо' : 'По треку налево',
          streetName: '',
          icon: delta > 0 ? Icons.turn_right : Icons.turn_left,
          location: anchors[i],
          distance: 0,
          routeOffsetMeters: offsets[i],
        ),
      );
    }
    result.add(
      RouteStep(
        instruction: 'Конец сохранённого трека',
        streetName: '',
        icon: Icons.flag,
        location: points.last,
        distance: 0,
        routeOffsetMeters: total,
      ),
    );
    return result;
  }
}
