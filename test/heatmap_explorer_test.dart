import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/workout_details.dart';
import 'package:pulsepath/services/heatmap_explorer.dart';
import 'package:pulsepath/services/developer_scenarios.dart';

void main() {
  SavedRoute ride(
    List<LatLng> points, {
    List<int> breaks = const [0],
    ActivityType type = ActivityType.mountainBiking,
    DateTime? date,
  }) => SavedRoute(
    title: 'Test',
    distance: '1 км',
    duration: '5 мин',
    surfaceSummary: '',
    finishPoint: points.last,
    routePoints: points,
    activityType: type,
    createdAt: date,
    workoutDetails: WorkoutDetails(segmentStarts: breaks),
  );
  const a = LatLng(56.48, 84.95),
      b = LatLng(56.481, 84.951),
      c = LatLng(56.482, 84.952);
  test(
    'repeated workouts increase heat; repeated laps do not multiply a workout',
    () {
      final once = HeatmapGeometry.build([
        ride([a, b]),
      ]);
      final twice = HeatmapGeometry.build([
        ride([a, b]),
        ride([a, b]),
      ]);
      final laps = HeatmapGeometry.build([
        ride([a, b, a, b]),
      ]);
      expect(once, isNotEmpty);
      expect(twice.every((e) => e.count == 2), isTrue);
      expect(laps.every((e) => e.count == 1), isTrue);
      expect(twice.length, once.length);
    },
  );
  test('manual pause, GPS gaps and dateline never create connecting heat', () {
    expect(
      HeatmapGeometry.build([
        ride([a, b], breaks: [0, 1]),
      ]),
      isEmpty,
    );
    expect(
      HeatmapGeometry.build([
        ride([a, const LatLng(57, 85)]),
      ]),
      isEmpty,
    );
    expect(
      HeatmapGeometry.build([
        ride([const LatLng(0, 179.999), const LatLng(0, -179.999)]),
      ]),
      isEmpty,
    );
  });
  test('invalid coordinates do not enter geometry', () {
    expect(
      HeatmapGeometry.build([
        ride([a, LatLng(double.nan, 0)]),
      ]),
      isEmpty,
    );
  });
  test('sport filters distinguish cycling, running, walking and driving', () {
    for (final type in ActivityType.values) {
      final r = ride([a, b], type: type);
      final matches = HeatSport.values.where(
        (s) => s != HeatSport.all && HeatmapFilter(sport: s).matches(r),
      );
      expect(matches.length, 1, reason: type.name);
    }
  });
  test('custom dates include full end day and exclude unknown dates', () {
    final filter = HeatmapFilter(
      start: DateTime(2026, 10, 1),
      end: DateTime(2026, 10, 22),
    );
    expect(
      filter.matches(ride([a, b], date: DateTime(2026, 10, 22, 23, 59))),
      isTrue,
    );
    expect(filter.matches(ride([a, b], date: DateTime(2026, 10, 23))), isFalse);
    expect(filter.matches(ride([a, b])), isFalse);
  });
  test(
    'inspection finds middle of a sparse segment but not a pause bridge',
    () {
      expect(HeatmapGeometry.distanceToTrack(b, ride([a, c])), lessThan(2));
      expect(
        HeatmapGeometry.distanceToTrack(b, ride([a, c], breaks: [0, 1])),
        greaterThan(50),
      );
    },
  );
  test(
    'developer fixtures are isolated and cover several sports and dates',
    () {
      final previews = DeveloperScenarios.heatmap(now: DateTime(2026, 10, 22));
      expect(previews, hasLength(14));
      expect(
        previews.every(
          (r) => r.localId.startsWith('preview-') && !r.cloudSynced,
        ),
        isTrue,
      );
      expect(previews.map((r) => r.activityType).toSet().length, 2);
    },
  );
}
