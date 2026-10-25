import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/saved_route.dart';
import '../models/workout_details.dart';

class RidePulseFrame {
  const RidePulseFrame({
    required this.point,
    required this.pointIndex,
    required this.meters,
    this.sample,
  });
  final LatLng? point;
  final int pointIndex;
  final double meters;
  final WorkoutSample? sample;
}

class RidePulseInsight {
  const RidePulseInsight(this.title, this.detail, {this.progress});
  final String title;
  final String detail;
  final double? progress;
}

/// Uses travelled distance, never interpolates a line across a GPS break.
/// Old recordings still have a useful distance replay without invented timing.
class RidePulse {
  RidePulse(this.route) {
    final starts = route.workoutDetails.segmentStarts.toSet();
    var meters = 0.0;
    for (var i = 0; i < points.length; i++) {
      if (i > 0 && !starts.contains(i))
        meters += _distance(points[i - 1], points[i]);
      cumulative.add(meters);
    }
    for (final sample in route.workoutDetails.samples) {
      if (sample.distanceMeters.isFinite &&
          sample.distanceMeters >= 0 &&
          (samples.isEmpty ||
              (sample.distanceMeters >= samples.last.distanceMeters &&
                  sample.activeSeconds >= samples.last.activeSeconds))) {
        samples.add(sample);
      }
    }
  }

  static const _distance = Distance();
  final SavedRoute route;
  List<LatLng> get points => route.routePoints;
  final List<double> cumulative = [];
  final List<WorkoutSample> samples = [];
  double get trackMeters => cumulative.lastOrNull ?? 0;
  double get meters =>
      route.distanceKm > 0 ? route.distanceKm * 1000 : trackMeters;
  bool get canReplay => points.length >= 2 && trackMeters > 0;
  int get gaps => route.workoutDetails.segmentStarts
      .where((s) => s > 0 && s < points.length)
      .toSet()
      .length;
  bool get hasAltitude =>
      samples.where((s) => s.altitudeMeters != null).length >= 2;

  int _indexAt(double distance) {
    var low = 0, high = cumulative.length - 1;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (cumulative[mid] < distance) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  double progressAtIndex(int index) =>
      trackMeters > 0 && index >= 0 && index < cumulative.length
      ? (cumulative[index] / trackMeters).clamp(0.0, 1.0)
      : 0;

  LatLng? pointAt(double progress) => points.isEmpty
      ? null
      : points[_indexAt(trackMeters * progress.clamp(0.0, 1.0))];

  RidePulseFrame frameAt(double progress) {
    final p = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
    if (points.isEmpty)
      return RidePulseFrame(point: null, pointIndex: 0, meters: meters * p);
    final index = _indexAt(trackMeters * p);
    WorkoutSample? nearest;
    if (samples.isNotEmpty) {
      var low = 0, high = samples.length - 1;
      while (low < high) {
        final mid = (low + high) ~/ 2;
        if (samples[mid].distanceMeters < meters * p) {
          low = mid + 1;
        } else {
          high = mid;
        }
      }
      nearest = samples[low];
      if (low > 0 &&
          (samples[low - 1].distanceMeters - meters * p).abs() <
              (nearest.distanceMeters - meters * p).abs())
        nearest = samples[low - 1];
      // A sparse or interrupted recording must not paint an entire ride with
      // the value of a single distant measurement.
      if ((nearest.distanceMeters - meters * p).abs() >
          math.max(50, meters * .015))
        nearest = null;
    }
    final linked = nearest?.trackPointIndex;
    final selectedIndex =
        linked != null && linked >= 0 && linked < points.length
        ? linked
        : index;
    return RidePulseFrame(
      point: points[selectedIndex],
      pointIndex: selectedIndex,
      meters: linked != null && linked >= 0 && linked < points.length
          ? nearest!.distanceMeters
          : meters * p,
      sample: nearest,
    );
  }

  List<RidePulseInsight> get insights {
    final data = route.workoutDetails;
    final active = Duration(
      seconds: route.durationSeconds ?? (route.durationMin * 60).round(),
    );
    final result = <RidePulseInsight>[];
    if (data.goal case final goal?) {
      final progress = goal.progress(meters, active, calories: route.calories);
      result.add(
        RidePulseInsight(
          progress >= 1
              ? 'Цель выполнена'
              : 'Путь к цели — ${(progress * 100).round()}%',
          goal.label,
          progress: progress,
        ),
      );
    }
    if (data.autoLaps.isNotEmpty) {
      final valid = data.autoLaps
          .where((lap) => lap.activeSeconds > 0 && lap.distanceMeters > 0)
          .toList();
      if (valid.isNotEmpty) {
        valid.sort((a, b) => b.speedKmh.compareTo(a.speedKmh));
        final best = valid.first;
        result.add(
          RidePulseInsight(
            'Самая быстрая отсечка — №${best.number}',
            '${(best.distanceMeters / 1000).toStringAsFixed(1)} км за ${workoutDurationLabel(Duration(seconds: best.activeSeconds))} · ${best.speedKmh.toStringAsFixed(1)} км/ч',
            progress: meters > 0
                ? data.autoLaps
                          .take(best.number)
                          .fold<double>(
                            0,
                            (sum, lap) => sum + lap.distanceMeters,
                          ) /
                      meters
                : null,
          ),
        );
      }
    }
    if (data.elapsedSeconds > active.inSeconds && active.inSeconds > 0) {
      result.add(
        RidePulseInsight(
          'В движении ${(active.inSeconds / data.elapsedSeconds * 100).round()}% времени',
          'Остановки — ${workoutDurationLabel(Duration(seconds: data.elapsedSeconds - active.inSeconds))}',
        ),
      );
    }
    if (result.isEmpty)
      result.add(
        RidePulseInsight(
          'Этот маршрут теперь в вашей истории',
          '${route.distanceKm.toStringAsFixed(2)} км · ${route.displayDuration} движения',
        ),
      );
    return result;
  }

  /// Personal comparisons require both similar distance and ordered geometry.
  /// Parallel roads within GPS precision can still match: UI says similar track.
  static bool matchesRoute(SavedRoute a, SavedRoute b) {
    if (a.activityType != b.activityType ||
        a.distanceKm < .5 ||
        b.distanceKm < .5 ||
        (a.distanceKm - b.distanceKm).abs() / a.distanceKm > .12 ||
        a.routePoints.length < 2 ||
        b.routePoints.length < 2)
      return false;
    if (_distance(a.routePoints.first, b.routePoints.first) > 150 ||
        _distance(a.routePoints.last, b.routePoints.last) > 150)
      return false;
    final left = RidePulse(a), right = RidePulse(b);
    if (!left.canReplay || !right.canReplay) return false;
    var near = 0;
    var total = 0.0;
    for (var i = 0; i < 24; i++) {
      final d = _distance(left.pointAt(i / 23)!, right.pointAt(i / 23)!);
      total += d;
      if (d <= 120) near++;
    }
    return near >= 21 && total / 24 <= 80;
  }

  int? indexNear(LatLng point, {double radius = 100}) {
    int? result;
    var best = radius;
    for (var i = 0; i < points.length; i++) {
      final distance = _distance(point, points[i]);
      if (distance <= best) {
        result = i;
        best = distance;
      }
    }
    return result;
  }
}
