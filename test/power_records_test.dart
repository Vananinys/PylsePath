import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/workout_details.dart';
import 'package:pulsepath/services/cycling_power.dart';
import 'package:pulsepath/services/personal_records.dart';
import 'package:pulsepath/services/achievements_service.dart';
import 'package:pulsepath/widgets/workout_analytics.dart';

List<WorkoutSample> samples(
  int seconds, {
  double watts = 200,
  int? pauseAfter,
}) => [
  for (var t = 0; t <= seconds; t += 10)
    WorkoutSample(
      activeSeconds: t,
      elapsedSeconds: t + (pauseAfter != null && t > pauseAfter ? 120 : 0),
      distanceMeters: t * 5.0,
      speedKmh: 18,
      estimatedWatts: watts,
    ),
];
SavedRoute ride(
  WorkoutDetails details, {
  ActivityType activity = ActivityType.cycling,
  String id = 'ride',
}) => SavedRoute(
  localId: id,
  title: 'Test',
  distance: '5 км',
  duration: '20 мин',
  durationSeconds: 1200,
  finishPoint: const LatLng(0, 0),
  routePoints: const [],
  surfaceSummary: '',
  activityType: activity,
  workoutDetails: details,
);
void main() {
  test(
    'road-load model has consistent units and rejects invalid telemetry',
    () {
      double? power(double speed, [double? grade]) => CyclingPower.estimate(
        speedKmh: speed,
        riderKg: 70,
        bikeKg: 15,
        gradePercent: grade,
      );
      expect(power(0), 0);
      expect(power(36), closeTo(352.8971, .01));
      expect(power(20, 5), greaterThan(power(20)!));
      expect(power(20, -5), lessThan(power(20)!));
      expect(power(double.nan), isNull);
      expect(power(150), isNull);
      expect(power(20, 40), isNull);
    },
  );
  test(
    'watts and model survive serialization; legacy telemetry has no watts',
    () {
      final d = WorkoutDetails(
        samples: samples(60),
        powerModel: const {'version': 1, 'rider_kg': 70, 'bike_kg': 15},
      );
      final restored = WorkoutDetails.fromJson(d.toJson());
      expect(restored.samples.last.estimatedWatts, 200);
      expect(restored.samples.last.elapsedSeconds, 60);
      expect(restored.powerModel!['version'], 1);
      expect(
        WorkoutDetails.fromJson({
          'samples': [
            {'seconds': 10, 'meters': 20, 'speed': 10},
          ],
        }).samples.single.estimatedWatts,
        isNull,
      );
      expect(
        WorkoutSample.fromJson({
          'seconds': 0,
          'meters': 0,
          'estimated_watts': -10,
        }).estimatedWatts,
        isNull,
      );
    },
  );
  test('continuous averages and work use weighted elapsed duration', () {
    final p = PowerSummary.fromSamples(samples(300, watts: 250));
    expect(p.coveredSeconds, 300);
    expect(p.averageWatts, 250);
    expect(p.energyJoules, 75000);
    expect(p.bestAverage(60), 250);
    expect(p.bestAverage(300), 250);
    expect(p.bestAverage(1200), isNull);
  });
  test('paused time and missing GPS break record windows', () {
    final p = PowerSummary.fromSamples(samples(300, pauseAfter: 150));
    expect(p.bestAverage(300), isNull);
    expect(p.bestAverage(60), 200);
    final s = samples(300);
    s[15] = const WorkoutSample(
      activeSeconds: 150,
      elapsedSeconds: 150,
      distanceMeters: 750,
    );
    expect(PowerSummary.fromSamples(s).bestAverage(300), isNull);
  });
  test(
    'duplicate active timestamp across pause cannot reconnect intervals',
    () {
      final s = [
        ...samples(60),
        for (var t = 60; t <= 120; t += 10)
          WorkoutSample(
            activeSeconds: t,
            elapsedSeconds: t + 120,
            distanceMeters: t * 5.0,
            speedKmh: 18,
            estimatedWatts: 200,
          ),
      ];
      final p = PowerSummary.fromSamples(s);
      expect(p.bestAverage(120), isNull);
      expect(p.bestAverage(60), 200);
    },
  );
  test('fixed distance records interpolate and reject paused attempts', () {
    final d = WorkoutDetails(samples: samples(1200));
    expect(PersonalRecords.fastestDistance(d, 5000), 1000);
    expect(PersonalRecords.fastestDistance(d, 10000), isNull);
    expect(
      PersonalRecords.fastestDistance(
        WorkoutDetails(samples: samples(1200, pauseAfter: 600)),
        5000,
      ),
      isNull,
    );
  });
  test(
    'records compare same activity and power achievements need power samples',
    () {
      final old = ride(
        const WorkoutDetails(),
        activity: ActivityType.running,
        id: 'old',
      );
      final current = ride(
        WorkoutDetails(
          samples: samples(300, watts: 200),
          powerModel: const {'version': 1},
        ),
      );
      expect(
        PersonalRecords.newRecords([
          old,
        ], current).any((r) => r.contains('1 мин')),
        isTrue,
      );
      final badges = AchievementsService.badges([current]);
      expect(
        badges.firstWhere((b) => b.title == 'Расчётные 200 Вт · минута').earned,
        isTrue,
      );
      expect(
        badges.firstWhere((b) => b.title == 'Расчётные 250 Вт · минута').earned,
        isFalse,
      );
      expect(
        AchievementsService.badges([old])
            .where((b) => b.earned && b.title.startsWith('Расчётные')),
        isEmpty,
      );
    },
  );
  testWidgets('saved power analytics fits a narrow display', (tester) async {
    tester.view.physicalSize = const Size(320, 750);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final r = ride(
      WorkoutDetails(
        samples: samples(300),
        powerModel: const {'version': 1, 'rider_kg': 70, 'bike_kg': 15},
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: WorkoutAnalytics(route: r)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Расчётная мощность'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
