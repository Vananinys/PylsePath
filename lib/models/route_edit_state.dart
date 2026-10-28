import 'package:latlong2/latlong.dart';

import 'activity_type.dart';
import 'saved_route.dart';
import 'workout_details.dart';
import 'route_step.dart';

/// Geometry for a planned copy. Recorded ride metrics are never carried over.
class RouteEditState {
  RouteEditState(
    List<LatLng> points, {
    Iterable<int> starts = const [0],
    this.estimatedSeconds,
    List<RouteStep> steps = const [],
    List<LatLng> controls = const [],
  }) : points = List.unmodifiable(points),
       steps = List.unmodifiable(steps),
       controls = List.unmodifiable(controls),
       starts = List.unmodifiable(
         ({
           if (points.isNotEmpty) 0,
           ...starts.where((i) => i > 0 && i < points.length),
         }.toList()..sort()),
       ) {
    if (points.length > 100000 ||
        points.any(
          (p) =>
              !p.latitude.isFinite ||
              !p.longitude.isFinite ||
              p.latitude.abs() > 90 ||
              p.longitude.abs() > 180,
        )) {
      throw const FormatException('Некорректные точки маршрута');
    }
  }
  final List<LatLng> points;
  final List<int> starts;
  final int? estimatedSeconds;
  final List<RouteStep> steps;
  final List<LatLng> controls;
  int get segmentCount => starts.length;
  double get meters {
    const measure = Distance();
    final gaps = starts.toSet();
    var sum = 0.0;
    for (var i = 1; i < points.length; i++) {
      if (!gaps.contains(i)) sum += measure(points[i - 1], points[i]);
    }
    return sum;
  }

  RouteEditState insert(int after, LatLng point) {
    final index = (after + 1).clamp(0, points.length);
    return RouteEditState(
      List.of(points)..insert(index, point),
      starts: [
        for (final s in starts)
          if (s > 0) s >= index ? s + 1 : s,
      ],
    );
  }

  RouteEditState move(int index, LatLng point) =>
      RouteEditState(List.of(points)..[index] = point, starts: starts);
  RouteEditState remove(int index) {
    RangeError.checkValidIndex(index, points);
    return RouteEditState(
      List.of(points)..removeAt(index),
      starts: [
        for (final s in starts)
          if (s > 0) s > index ? s - 1 : s,
      ],
    );
  }

  RouteEditState trim(int first, int last) {
    RangeError.checkValidRange(first, last + 1, points.length);
    if (last < first) throw const FormatException('Пустой участок');
    return RouteEditState(
      points.sublist(first, last + 1),
      starts: [
        for (final s in starts)
          if (s > first && s <= last) s - first,
      ],
    );
  }

  RouteEditState reversed() {
    final chunks = WorkoutDetails.splitTrack(points, starts);
    // splitTrack drops singletons; retain them when reversing disconnected data.
    final bounds = [...starts, points.length];
    final output = <LatLng>[];
    final breaks = <int>[];
    for (var i = bounds.length - 2; i >= 0; i--) {
      breaks.add(output.length);
      output.addAll(points.sublist(bounds[i], bounds[i + 1]).reversed);
    }
    assert(chunks.length <= starts.length);
    return RouteEditState(output, starts: breaks);
  }

  RouteEditState closeLoop() {
    if (starts.length != 1 || points.length < 2) {
      throw const FormatException('Для круга нужен один непрерывный участок');
    }
    return points.last == points.first
        ? this
        : insert(points.length - 1, points.first);
  }

  RouteEditState reorder(int from, int to) {
    if (segmentCount > 1 || points.length > 32) {
      throw const FormatException(
        'Перестановка доступна для контрольных точек одного участка',
      );
    }
    RangeError.checkValidIndex(from, points);
    RangeError.checkValidIndex(to, points);
    final next = List<LatLng>.of(points);
    next.insert(to, next.removeAt(from));
    return RouteEditState(next);
  }

  RouteEditState controlPoints() {
    if (segmentCount > 1) {
      throw const FormatException('Сначала выберите один непрерывный участок');
    }
    if (points.length <= 10) return this;
    return RouteEditState([
      for (var i = 0; i < 10; i++)
        points[(i * (points.length - 1) / 9).round()],
    ]);
  }

  SavedRoute plannedCopy({
    required String title,
    required ActivityType activity,
    String notes = '',
    String collection = '',
  }) {
    final clean = title.trim();
    if (clean.isEmpty ||
        clean.length > 120 ||
        notes.length > 2000 ||
        points.length < 2) {
      throw const FormatException(
        'Укажите название до 120 символов и хотя бы две точки',
      );
    }
    return SavedRoute(
      title: clean,
      activityType: activity,
      routePoints: points,
      finishPoint: points.last,
      createdAt: DateTime.now(),
      distance: '${(meters / 1000).toStringAsFixed(2)} км',
      distanceMeters: meters,
      duration: estimatedSeconds == null
          ? 'Время не рассчитано'
          : '${estimatedSeconds! ~/ 60} мин',
      durationSeconds: estimatedSeconds ?? 0,
      surfaceSummary: estimatedSeconds == null
          ? 'Линия без привязки к дорогам'
          : 'Построено по дорогам',
      routeNotes: notes,
      collection: collection,
      workoutDetails: WorkoutDetails(segmentStarts: starts),
      navigationSteps: steps,
      viaPoints: controls.length > 2
          ? controls.sublist(1, controls.length - 1)
          : const [],
    );
  }
}
