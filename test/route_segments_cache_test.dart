import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/workout_details.dart';

List<LatLng> route({
  required int points,
  required double offsetLon,
  LatLng start = const LatLng(55.0, 83.0),
}) => [
      for (var i = 0; i < points; i++)
        LatLng(start.latitude + i * 0.0005, start.longitude + offsetLon * i),
    ];

Map<String, dynamic> savedRouteJson(String id, List<LatLng> points,
        {List<int> segmentStarts = const []}) =>
    {
      'localId': id,
      'title': 'Saved route',
      'distance': '1 km',
      'duration': '10 min',
      'surfaceSummary': '',
      'finishLat': points.last.latitude,
      'finishLon': points.last.longitude,
      'routePoints': [
        for (final p in points) [p.latitude, p.longitude],
      ],
      if (segmentStarts.isNotEmpty)
        'workoutDetails': {'segment_starts': segmentStarts},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MapNavigationController controller;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkoutHistoryRepository.resetInstancesForTesting();
    controller = MapNavigationController();
  });
  tearDown(() => controller.dispose());

  List<List<LatLng>> expectedSegments() => WorkoutDetails.splitTrack(
        controller.routePoints,
        controller.routeSegmentStarts,
      );

  test('Imported track with gaps matches splitTrack and repeats by cache', () {
    final points = [
      ...route(points: 3, offsetLon: 0.0005),
      ...route(points: 2, offsetLon: 0.0005, start: const LatLng(56.0, 84.0)),
    ];
    expect(controller.loadImportedTrack(points, segmentStarts: [0, 3]), isTrue);

    final segments = controller.routeSegments;
    expect(segments, expectedSegments());
    expect(segments.map((s) => s.length), [3, 2]);
    // Повторное обращение возвращает тот же кэш без пересчёта.
    expect(identical(controller.routeSegments, segments), isTrue);
  });

  test('Cached segments cannot be mutated by consumers', () {
    final points = route(points: 4, offsetLon: 0.0005);
    expect(controller.loadImportedTrack(points), isTrue);
    final segments = controller.routeSegments;
    expect(() => segments.add(const []), throwsUnsupportedError);
    expect(() => segments.first.add(const LatLng(0, 0)), throwsUnsupportedError);
    expect(() => segments.first[0] = const LatLng(0, 0), throwsUnsupportedError);
    // Кэш не пострадал.
    expect(segments, expectedSegments());
  });

  test('clearRoute invalidates the cache and next access rebuilds', () {
    expect(controller.loadImportedTrack(route(points: 4, offsetLon: 0.0005)),
        isTrue);
    expect(controller.routeSegments, hasLength(1));
    controller.clearRoute();
    expect(controller.routeSegments, isEmpty);
    expect(controller.routeSegments, expectedSegments());
  });

  test(
    'Activity change clears a built route and the cache follows',
    () {
      controller.setRouteForTesting(
        points: route(points: 4, offsetLon: 0.0005),
        steps: const [],
      );
      expect(controller.routeSegments, isNotEmpty);
      controller.setSportMode(SportMode.running);
      expect(controller.routePoints, isEmpty);
      expect(controller.routeSegments, isEmpty);
    },
  );

  test('Saved route with gaps loads segments equal to a fresh split', () {
    final first = route(points: 3, offsetLon: 0.0005);
    final second = route(points: 2, offsetLon: 0.0005,
        start: const LatLng(56.0, 84.0));
    controller.loadSavedRoute(
      SavedRoute.fromJson(savedRouteJson(
        'saved-1',
        [...first, ...second],
        segmentStarts: [0, 3],
      )),
    );
    final segments = controller.routeSegments;
    expect(segments, expectedSegments());
    expect(segments.map((s) => s.length), [3, 2]);
    expect(identical(controller.routeSegments, segments), isTrue);
  });

  test('A different track replaces the cached segments', () {
    expect(controller.loadImportedTrack(route(points: 4, offsetLon: 0.0005)),
        isTrue);
    expect(controller.routeSegments, hasLength(1));
    expect(controller.loadImportedTrack(route(points: 5, offsetLon: 0.001)),
        isTrue);
    final segments = controller.routeSegments;
    expect(segments, expectedSegments());
    expect(segments.single, hasLength(5));
  });

  test('Navigation keeps one cached instance across GPS updates', () {
    final points = route(points: 200, offsetLon: 0.0005);
    expect(controller.loadImportedTrack(points), isTrue);
    controller.setNavigating(true);
    final cached = controller.routeSegments;
    final now = DateTime.now();
    for (var i = 0; i < 50; i++) {
      // Точки идут вдоль маршрута: отклонение считается на каждой точке.
      controller.applyGpsSampleForTesting(
        Position(
          latitude: points[i].latitude,
          longitude: points[i].longitude,
          timestamp: now.add(Duration(seconds: i)),
          accuracy: 5,
          altitude: 0,
          altitudeAccuracy: 1,
          heading: 0,
          headingAccuracy: 1,
          speed: 3,
          speedAccuracy: 1,
        ),
        observedAt: now.add(Duration(seconds: i)),
      );
      expect(identical(controller.routeSegments, cached), isTrue);
    }
    expect(cached, expectedSegments());
  });
}
