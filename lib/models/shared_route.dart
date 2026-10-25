import 'package:latlong2/latlong.dart' hide Path;

import 'activity_type.dart';
import 'saved_route.dart';
import 'workout_details.dart';

/// A bounded snapshot: opening a share never requires access to private rides.
class SharedRoute {
  const SharedRoute({
    required this.title,
    required this.kind,
    required this.distanceKm,
    required this.durationSeconds,
    required this.points,
    this.activity = ActivityType.cycling,
    this.segmentStarts = const [0],
  });
  final String title;
  final String kind;
  final double distanceKm;
  final int durationSeconds;
  final List<LatLng> points;
  final ActivityType activity;
  final List<int> segmentStarts;
  String get label => kind == 'ride' ? 'Заезд' : 'Маршрут';

  factory SharedRoute.fromSavedRoute(
    SavedRoute route, {
    String kind = 'ride',
    bool includeTrack = true,
    double hideRadiusMeters = 0,
  }) {
    final source = includeTrack ? route.routePoints : <LatLng>[];
    final radius = hideRadiusMeters.isFinite
        ? hideRadiusMeters.clamp(0.0, 5000.0)
        : 0.0;
    final originalStarts = route.workoutDetails.segmentStarts.toSet();
    final chunks = <List<LatLng>>[];
    var current = <LatLng>[];
    const distance = Distance();
    for (var i = 0; i < source.length; i++) {
      final point = source[i];
      final hidden =
          radius > 0 &&
          (distance(source.first, point) < radius ||
              distance(source.last, point) < radius);
      if (hidden || originalStarts.contains(i)) {
        if (current.length >= 2) chunks.add(current);
        current = [];
      }
      if (!hidden) current.add(point);
    }
    if (current.length >= 2) chunks.add(current);
    final stride = (source.length / 1000).ceil().clamp(1, 1000000);
    final points = <LatLng>[];
    final starts = <int>[];
    for (final chunk in chunks) {
      if (points.length + 2 > 1200) break;
      starts.add(points.length);
      final last = chunk.length - 1;
      for (var i = 0; i < last && points.length < 1199; i += stride) {
        points.add(chunk[i]);
      }
      points.add(chunk.last);
    }
    return SharedRoute(
      title: route.title.length > 240
          ? route.title.substring(0, 240)
          : route.title,
      kind: kind,
      distanceKm: route.distanceKm,
      durationSeconds: (route.durationMin * 60).round(),
      points: points,
      activity: route.activityType,
      segmentStarts: starts,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'title': title,
    'kind': kind,
    'distance_km': distanceKm,
    'duration_seconds': durationSeconds,
    'activity': activity.name,
    'segment_starts': segmentStarts,
    'points': points.map((p) => [p.latitude, p.longitude]).toList(),
  };

  static SharedRoute? tryParse(Object? raw) {
    if (raw is! Map || raw['version'] != 1) return null;
    try {
      final title = raw['title'];
      final km = raw['distance_km'];
      final seconds = raw['duration_seconds'];
      final coords = raw['points'];
      if (title is! String ||
          title.length > 240 ||
          km is! num ||
          !km.isFinite ||
          km < 0 ||
          km > 100000 ||
          seconds is! num ||
          !seconds.isFinite ||
          seconds < 0 ||
          seconds > 31536000 ||
          coords is! List ||
          coords.length > 1201 ||
          !['ride', 'route'].contains(raw['kind'])) {
        return null;
      }
      final points = <LatLng>[];
      for (final pair in coords) {
        if (pair is! List ||
            pair.length != 2 ||
            pair[0] is! num ||
            pair[1] is! num) {
          return null;
        }
        final lat = (pair[0] as num).toDouble(),
            lon = (pair[1] as num).toDouble();
        if (!lat.isFinite ||
            !lon.isFinite ||
            lat.abs() > 90 ||
            lon.abs() > 180) {
          return null;
        }
        points.add(LatLng(lat, lon));
      }
      final starts = <int>{0};
      for (final value
          in raw['segment_starts'] is List
              ? raw['segment_starts'] as List
              : const []) {
        if (value is int && value >= 0 && value < points.length) {
          starts.add(value);
        }
      }
      return SharedRoute(
        title: title,
        kind: raw['kind'],
        distanceKm: km.toDouble(),
        durationSeconds: seconds.toInt(),
        points: points,
        activity:
            ActivityType.values
                .where((a) => a.name == raw['activity'])
                .firstOrNull ??
            ActivityType.cycling,
        segmentStarts: starts.toList()..sort(),
      );
    } catch (_) {
      return null;
    }
  }

  List<List<LatLng>> get segments {
    final boundaries = [
      ...segmentStarts.where((s) => s >= 0 && s < points.length),
      points.length,
    ]..sort();
    return [
      for (var i = 0; i < boundaries.length - 1; i++)
        if (boundaries[i + 1] - boundaries[i] >= 2)
          points.sublist(boundaries[i], boundaries[i + 1]),
    ];
  }

  SavedRoute toSavedRoute() => SavedRoute(
    createdAt: DateTime.now(),
    title: title,
    distance: '${distanceKm.toStringAsFixed(1)} км',
    duration: '${(durationSeconds / 60).round()} мин',
    surfaceSummary: '',
    finishPoint: points.isEmpty ? const LatLng(0, 0) : points.last,
    routePoints: points,
    activityType: activity,
    distanceMeters: distanceKm * 1000,
    durationSeconds: durationSeconds,
    workoutDetails: WorkoutDetails(segmentStarts: segmentStarts),
  );
}
