import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/data/navigation_preferences.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/ride_moment.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/shared_route.dart';
import 'package:pulsepath/models/workout_details.dart';
import 'package:pulsepath/services/ride_pulse.dart';
import 'package:pulsepath/widgets/ride_pulse_view.dart';

SavedRoute ride({
  String id = 'ride-a',
  List<LatLng>? points,
  WorkoutDetails details = const WorkoutDetails(),
  double km = 1,
}) => SavedRoute(
  localId: id,
  title: 'Тихий круг',
  distance: '$km км',
  duration: '5 мин',
  distanceMeters: km * 1000,
  durationSeconds: 300,
  surfaceSummary: '',
  finishPoint: const LatLng(55, 83),
  routePoints:
      points ??
      [const LatLng(55, 83), const LatLng(55, 83.01), const LatLng(55, 83.02)],
  activityType: ActivityType.cycling,
  createdAt: DateTime(2026, 10, 24),
  workoutDetails: details,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkoutHistoryRepository.resetInstancesForTesting();
  });

  test(
    'distance replay never counts or draws a connection through GPS gaps',
    () {
      final route = ride(
        points: [
          const LatLng(55, 83),
          const LatLng(55, 83.001),
          const LatLng(56, 84),
          const LatLng(56, 84.001),
        ],
        details: const WorkoutDetails(segmentStarts: [0, 2]),
      );
      final pulse = RidePulse(route);
      expect(pulse.trackMeters, inInclusiveRange(120, 130));
      expect(pulse.gaps, 1);
      expect(pulse.frameAt(.5).point, isIn(route.routePoints));
      expect(pulse.frameAt(.5).sample, isNull);
      expect(
        WorkoutDetails.splitTrack(route.routePoints, [0, 2]),
        hasLength(2),
      );
    },
  );

  test('legacy sparse telemetry does not invent speed at distant places', () {
    final pulse = RidePulse(
      ride(
        details: const WorkoutDetails(
          samples: [
            WorkoutSample(activeSeconds: 0, distanceMeters: 0, speedKmh: 20),
          ],
        ),
      ),
    );
    expect(pulse.frameAt(0).sample?.speedKmh, 20);
    expect(pulse.frameAt(.8).sample, isNull);
    expect(pulse.frameAt(1).point, pulse.points.last);
    expect(pulse.hasAltitude, isFalse);
  });

  test(
    'same distance does not make a different or reversed route comparable',
    () {
      final a = ride();
      final repeated = ride(
        id: 'b',
        points: [
          const LatLng(55.00005, 83),
          const LatLng(55.00005, 83.01),
          const LatLng(55.00005, 83.02),
        ],
      );
      final elsewhere = ride(
        id: 'c',
        points: [const LatLng(56, 84), const LatLng(56, 84.01)],
      );
      final reverse = ride(id: 'd', points: a.routePoints.reversed.toList());
      expect(RidePulse.matchesRoute(a, repeated), isTrue);
      expect(RidePulse.matchesRoute(a, elsewhere), isFalse);
      expect(RidePulse.matchesRoute(a, reverse), isFalse);
    },
  );

  test('new telemetry and private memories survive JSON; malformed memories do not hide rides', () {
    const moment = RideMoment(
      id: 'm1',
      kind: RideMomentKind.rest,
      pointIndex: 1,
      distanceMeters: 450,
      note: 'Тихое место у воды',
    );
    final details = WorkoutDetails.fromJson({
      'samples': [
        {
          'seconds': 10,
          'meters': 20,
          'speed': 12,
          'track_point_index': 1,
          'altitude_meters': 140,
        },
      ],
      'ride_moments': [
        moment.toJson(),
        {'id': 'bad', 'kind': 'unknown'},
        {...moment.toJson(), 'meters': double.nan},
      ],
    });
    final restored = WorkoutDetails.fromJson(details.toJson());
    expect(restored.rideMoments.single.note, moment.note);
    expect(restored.samples.single.altitudeMeters, 140);
    expect(restored.samples.single.trackPointIndex, 1);
    final exported = SharedRoute.fromSavedRoute(ride(details: restored))
        .toJson()
        .toString();
    expect(exported, isNot(contains('ride_moments')));
    expect(exported, isNot(contains(moment.note)));
  });

  test('saving memories merges the latest row and queues it without duplicating the ride', () async {
    final repo = WorkoutHistoryRepository();
    final original = ride(
      details: const WorkoutDetails(
        notes: 'Сохранить заметку',
        samples: [
          WorkoutSample(activeSeconds: 10, distanceMeters: 30, speedKmh: 12),
        ],
      ),
    );
    await repo.addWorkout(original);
    final changedJson = original.toJson()..['calories'] = 120;
    await repo.replaceRoute(original, SavedRoute.fromJson(changedJson));
    const moment = RideMoment(
      id: 'm1',
      kind: RideMomentKind.climb,
      pointIndex: 1,
      distanceMeters: 500,
      note: 'Крутой подъём',
    );
    final saved = await repo.addRideMoment(original, moment);
    expect(saved.calories, 120);
    expect(saved.workoutDetails.notes, 'Сохранить заметку');
    expect(saved.workoutDetails.samples.single.speedKmh, 12);
    expect(saved.cloudSynced, isFalse);
    await repo.addRideMoment(saved, moment);
    await repo.load();
    expect(repo.workoutHistory, hasLength(1));
    expect(repo.workoutHistory.single.workoutDetails.rideMoments, hasLength(1));
    expect(
      () => repo.addRideMoment(
        saved,
        const RideMoment(
          id: 'bad',
          kind: RideMomentKind.rest,
          pointIndex: 100,
          distanceMeters: 500,
        ),
      ),
      throwsStateError,
    );
  });

  testWidgets(
    'replay and personal place save work on a narrow phone without map tiles',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final cachedOnly = NavigationPreferences.instance.cachedMapOnly;
      NavigationPreferences.instance.cachedMapOnly = true;
      addTearDown(
        () => NavigationPreferences.instance.cachedMapOnly = cachedOnly,
      );
      final route = ride(
        details: const WorkoutDetails(
          samples: [
            WorkoutSample(
              activeSeconds: 0,
              distanceMeters: 0,
              speedKmh: 10,
              trackPointIndex: 0,
              altitudeMeters: 100,
            ),
            WorkoutSample(
              activeSeconds: 300,
              distanceMeters: 1000,
              speedKmh: 15,
              trackPointIndex: 2,
              altitudeMeters: 110,
            ),
          ],
        ),
      );
      await WorkoutHistoryRepository().addWorkout(route);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: RidePulseView(route: route)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byType(Slider));
      await tester.drag(find.byType(Slider), const Offset(160, 0));
      await tester.pump();
      await tester.ensureVisible(find.text('Запомнить'));
      await tester.tap(find.text('Запомнить'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подъём'));
      await tester.enterText(find.byType(TextField), 'Личный ориентир');
      await tester.ensureVisible(find.text('Сохранить место'));
      await tester.tap(find.text('Сохранить место'));
      await tester.pumpAndSettle();
      expect(
        WorkoutHistoryRepository()
            .workoutHistory
            .single
            .workoutDetails
            .rideMoments
            .single
            .note,
        'Личный ориентир',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'empty-track recap fits a narrow phone and keeps useful results',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RidePulseView(route: ride(points: [])),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('ВАШ ПУЛЬС МАРШРУТА'), findsOneWidget);
      expect(find.textContaining('GPS-трек не записан'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'cloud memories update an existing ride while preserving local telemetry',
    () async {
      final repo = WorkoutHistoryRepository();
      const first = RideMoment(
        id: 'first',
        kind: RideMomentKind.rest,
        pointIndex: 1,
        distanceMeters: 500,
        note: 'Локальная память',
      );
      const second = RideMoment(
        id: 'second',
        kind: RideMomentKind.climb,
        pointIndex: 2,
        distanceMeters: 1000,
        note: 'С другого устройства',
      );
      final local = ride(
        details: const WorkoutDetails(
          rideMoments: [first],
          samples: [
            WorkoutSample(activeSeconds: 20, distanceMeters: 100, speedKmh: 18),
          ],
        ),
      );
      await repo.addWorkout(local);
      final remote = ride(details: const WorkoutDetails(rideMoments: [second]));
      await repo.mergeRemote([remote]);
      final result = repo.workoutHistory.single;
      expect(result.workoutDetails.rideMoments.map((m) => m.id).toSet(), {
        'first',
        'second',
      });
      expect(result.workoutDetails.samples.single.speedKmh, 18);
      expect(result.cloudSynced, isFalse);
    },
  );
}
