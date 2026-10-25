import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/saved_route.dart';

enum HeatSport {
  all('Все'),
  cycling('Вело'),
  running('Бег'),
  walking('Ходьба'),
  driving('Авто');

  const HeatSport(this.label);
  final String label;
}

class HeatmapFilter {
  const HeatmapFilter({this.sport = HeatSport.all, this.start, this.end});
  final HeatSport sport;
  final DateTime? start, end;
  bool matches(SavedRoute ride) {
    final date = ride.recordedDateTime?.toLocal();
    if ((start != null || end != null) && date == null) return false;
    if (start != null && date!.isBefore(start!)) return false;
    if (end != null &&
        !date!.isBefore(DateTime(end!.year, end!.month, end!.day + 1)))
      return false;
    return switch (sport) {
      HeatSport.all => true,
      HeatSport.running => ride.activityType.isRunning,
      HeatSport.walking =>
        ride.activityType.isFoot && !ride.activityType.isRunning,
      HeatSport.driving => ride.activityType.name == 'driving',
      HeatSport.cycling =>
        !ride.activityType.isFoot && ride.activityType.name != 'driving',
    };
  }
}

class HeatEdge {
  const HeatEdge(this.a, this.b, this.count);
  final LatLng a, b;
  final int count;
}

/// Fine Mercator grid merges repeat passes, retaining actual track geometry.
/// A ride contributes once per edge, regardless of sampling frequency/laps.
class HeatmapGeometry {
  static bool valid(LatLng p) =>
      p.latitude.isFinite &&
      p.longitude.isFinite &&
      p.latitude.abs() <= 85 &&
      p.longitude.abs() <= 180;
  static (int, int) _cell(LatLng p) {
    const radius = 6378137.0, size = 16.0;
    return (
      (radius * p.longitude * math.pi / 180 / size).floor(),
      (radius *
              math.log(math.tan(math.pi / 4 + p.latitude * math.pi / 360)) /
              size)
          .floor(),
    );
  }

  static List<HeatEdge> build(List<SavedRoute> rides) {
    final counts = <String, int>{};
    final geometry = <String, (LatLng, LatLng)>{};
    const distance = Distance();
    for (final ride in rides) {
      final seen = <String>{};
      final breaks = ride.workoutDetails.segmentStarts.toSet();
      for (var i = 1; i < ride.routePoints.length; i++) {
        if (breaks.contains(i)) continue;
        final a = ride.routePoints[i - 1], b = ride.routePoints[i];
        if (!valid(a) || !valid(b) || (a.longitude - b.longitude).abs() > 180)
          continue;
        final meters = distance(a, b);
        if (!meters.isFinite || meters > 500 || meters < .1) continue;
        final steps = (meters / 8).ceil().clamp(1, 100);
        for (var j = 0; j < steps; j++) {
          LatLng lerp(double t) => LatLng(
            a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t,
          );
          final p = lerp(j / steps), q = lerp((j + 1) / steps);
          final c = _cell(p), d = _cell(q);
          final first = '${c.$1}:${c.$2}', second = '${d.$1}:${d.$2}';
          final key = first.compareTo(second) <= 0
              ? '$first/$second'
              : '$second/$first';
          geometry.putIfAbsent(key, () => (p, q));
          // Keep the farthest endpoints inside the same cell, not only its first sample.
          if (c == d) {
            final old = geometry[key]!;
            if (distance(old.$1, q) > distance(old.$1, old.$2))
              geometry[key] = (old.$1, q);
          }
          if (seen.add(key))
            counts.update(key, (n) => n + 1, ifAbsent: () => 1);
        }
      }
    }
    return [
      for (final e in geometry.entries)
        HeatEdge(e.value.$1, e.value.$2, counts[e.key]!),
    ];
  }

  /// Used for map inspection; includes segments crossing the tap vicinity.
  static double distanceToTrack(LatLng point, SavedRoute ride) {
    var best = double.infinity;
    const distance = Distance();
    final breaks = ride.workoutDetails.segmentStarts.toSet();
    final cosLat = math.cos(point.latitude * math.pi / 180);
    for (var i = 0; i < ride.routePoints.length; i++) {
      final b = ride.routePoints[i];
      if (!valid(b)) continue;
      best = math.min(best, distance(point, b));
      if (i == 0 || breaks.contains(i)) continue;
      final a = ride.routePoints[i - 1];
      if (!valid(a) ||
          distance(a, b) > 500 ||
          (a.longitude - b.longitude).abs() > 180)
        continue;
      final ax = (a.longitude - point.longitude) * cosLat,
          ay = a.latitude - point.latitude;
      final bx = (b.longitude - point.longitude) * cosLat,
          by = b.latitude - point.latitude;
      final dx = bx - ax, dy = by - ay;
      final denominator = dx * dx + dy * dy;
      final t = denominator == 0
          ? 0.0
          : (-(ax * dx + ay * dy) / denominator).clamp(0.0, 1.0);
      best = math.min(
        best,
        math.sqrt(math.pow(ax + t * dx, 2) + math.pow(ay + t * dy, 2)) * 111320,
      );
    }
    return best;
  }
}
