import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/data/workout_draft_store.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/activity_type.dart' as activity;
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/workout_details.dart';
import 'package:pulsepath/models/workout_record.dart';
import 'package:pulsepath/services/rides_service.dart';
import 'package:pulsepath/utils/gpx_utils.dart';
import 'package:pulsepath/widgets/swipe_to_reply.dart';
import 'package:pulsepath/widgets/workout_finish_sheet.dart';
import 'package:pulsepath/widgets/workout_analytics.dart';
import 'package:pulsepath/widgets/workout_stats_bottom_sheet.dart';
import 'package:pulsepath/data/saved_routes_repository.dart';

class TrainingClock implements Stopwatch {
  Duration _elapsed = Duration.zero;
  bool _running = false;
  void advance(int seconds) {
    if (_running) _elapsed += Duration(seconds: seconds);
  }

  @override
  bool get isRunning => _running;
  @override
  Duration get elapsed => _elapsed;
  @override
  int get elapsedMilliseconds => _elapsed.inMilliseconds;
  @override
  int get elapsedMicroseconds => _elapsed.inMicroseconds;
  @override
  int get elapsedTicks => elapsedMicroseconds;
  @override
  int get frequency => 1000000;
  @override
  void start() => _running = true;
  @override
  void stop() => _running = false;
  @override
  void reset() => _elapsed = Duration.zero;
}

Position fix(double latitude, DateTime timestamp, {double accuracy = 5}) =>
    Position(
      latitude: latitude,
      longitude: 83,
      timestamp: timestamp,
      accuracy: accuracy,
      altitude: 100,
      altitudeAccuracy: 1,
      heading: 0,
      headingAccuracy: 1,
      speed: 3,
      speedAccuracy: 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkoutHistoryRepository.resetInstancesForTesting();
  });

  test('Active duration excludes pauses; goals, laps, title and notes survive save', () async {
    final clock = TrainingClock();
    final controller = MapNavigationController(activeClock: clock);
    controller.setSportMode(SportMode.running);
    controller.setWorkoutGoal(const WorkoutGoal(WorkoutGoalKind.duration, 120));
    controller.startWorkout();
    final stableSessionId = controller.workoutSessionId;
    final stableSessionStartedAt = controller.workoutSessionStartedAt;
    expect(stableSessionId, isNotNull);
    clock.advance(50);
    controller.markWorkoutLap();
    controller.pauseWorkout();
    clock.advance(900);
    expect(controller.activeWorkoutDuration.inSeconds, 50);
    controller.resumeWorkout();
    expect(controller.workoutSessionId, stableSessionId);
    expect(controller.workoutSessionStartedAt, stableSessionStartedAt);
    clock.advance(80);
    expect(controller.workoutGoalProgress, 1);
    final saved = await controller.finishAndSaveWorkout(
      title: 'Лёгкий бег',
      notes: 'Хорошая тренировка',
      effort: 3,
    );
    expect(saved?.durationSeconds, 130);
    expect(saved?.localId, stableSessionId);
    expect(saved?.title, 'Лёгкий бег');
    expect(saved?.activityType, activity.ActivityType.running);
    expect(saved?.workoutDetails.notes, 'Хорошая тренировка');
    expect(saved?.workoutDetails.laps.map((lap) => lap.activeSeconds), [
      50,
      80,
    ]);
    final restored = SavedRoute.fromJson(saved!.toJson());
    expect(restored.workoutDetails.goal?.target, 120);
    expect(
      restored
          .withSyncState(remoteId: 'remote', cloudSynced: true)
          .workoutDetails
          .notes,
      'Хорошая тренировка',
    );
    controller.dispose();
  });

  test(
    'Long GPS gaps and manual pauses do not add bridging distance',
    () async {
      final controller = MapNavigationController(activeClock: TrainingClock());
      controller.setAutoPauseEnabled(false);
      controller.startWorkout();
      final start = DateTime.now().toUtc();
      for (final sample in [
        (55.0, 0),
        (55.0005, 10),
        (55.001, 20),
        (55.003, 80),
        (55.0035, 90),
      ]) {
        controller.applyGpsSampleForTesting(
          fix(sample.$1, start.add(Duration(seconds: sample.$2))),
        );
      }
      expect(controller.totalDistanceMeters, inInclusiveRange(150, 180));
      expect(controller.recordedSegments.map((s) => s.length), [3, 2]);
      expect(controller.maxWorkoutSpeedKmh, greaterThan(0));
      final before = controller.totalDistanceMeters;
      controller.pauseWorkout();
      controller.resumeWorkout();
      controller.applyGpsSampleForTesting(
        fix(56, start.add(const Duration(seconds: 120))),
      );
      expect(controller.totalDistanceMeters, closeTo(before, .01));
      expect(controller.recordedSegments.length, 3);
      controller.dispose();
    },
  );

  test(
    'Workout details recover with the draft and round-trip through cloud rows',
    () async {
      const data = WorkoutDetails(
        goal: WorkoutGoal(WorkoutGoalKind.distance, 10000),
        maxSpeedKmh: 27,
        notes: 'Заметка',
        effort: 4,
        segmentStarts: [2],
        laps: [
          WorkoutLap(
            number: 1,
            distanceMeters: 500,
            activeSeconds: 90,
            endSeconds: 90,
          ),
        ],
      );
      final draft = WorkoutDraft(
        ownerId: 'owner',
        localId: 'ride',
        startedAt: DateTime.now(),
        activeMilliseconds: 90000,
        distanceMeters: 500,
        elevationGainMeters: 2,
        activity: activity.ActivityType.cycling,
        path: const [LatLng(55, 83)],
        details: data,
      );
      await WorkoutDraftStore('owner').save(draft);
      final loaded = await WorkoutDraftStore('owner').load();
      expect(loaded?.details.toJson(), data.toJson());
      final row = RidesService.buildRow(
        userId: 'owner',
        distanceKm: .5,
        durationSeconds: 90,
        workoutDetails: {...data.toJson(), 'title': 'Мой заезд'},
      );
      final route = RidesService.rideFromRow({...row, 'id': 'ride'});
      expect(route?.title, 'Мой заезд');
      expect(WorkoutRecord.fromSavedRoute(route!).maxSpeed, 27);
    },
  );

  test('GPX preserves separate segments without inventing timestamps', () {
    const points = [
      LatLng(55, 83),
      LatLng(55.001, 83),
      LatLng(56, 83),
      LatLng(56.001, 83),
    ];
    final gpx = GpxUtils.build(points: points, segmentStarts: [2]);
    expect('<trkseg>'.allMatches(gpx).length, 2);
    expect(GpxUtils.parse(gpx), points);
    expect(gpx.contains('<time>'), isFalse);
  });

  test('Invalid optional telemetry cannot hide an otherwise valid ride', () {
    final details = WorkoutDetails.fromJson({
      'max_speed_kmh': -1,
      'effort': 99,
      'goal': {'kind': 'duration', 'target': -10},
      'samples': [
        {'seconds': 10, 'meters': 1, 'speed': -5},
        'bad',
      ],
    });
    expect(details.goal, isNull);
    expect(details.samples, isEmpty);
    expect(details.effort, isNull);
    expect(
      workoutPace(1000, const Duration(minutes: 5, seconds: 30)),
      '5:30 /км',
    );
  });

  testWidgets('Reply triggers only for a deliberate left swipe', (
    tester,
  ) async {
    var replies = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SwipeToReply(
              onReply: () => replies++,
              child: const SizedBox(
                width: 220,
                height: 70,
                child: Text('Свайпните влево'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.timedDrag(
      find.text('Свайпните влево'),
      const Offset(90, 0),
      const Duration(milliseconds: 450),
    );
    await tester.pumpAndSettle();
    expect(replies, 0);
    await tester.timedDrag(
      find.text('Свайпните влево'),
      const Offset(-30, 0),
      const Duration(milliseconds: 450),
    );
    await tester.pumpAndSettle();
    expect(replies, 0);
    await tester.timedDrag(
      find.text('Свайпните влево'),
      const Offset(-100, 0),
      const Duration(milliseconds: 450),
    );
    await tester.pumpAndSettle();
    expect(replies, 1);
    expect(find.text('Свайпните влево'), findsOneWidget);
  });

  testWidgets('Training analytics fits a narrow screen with notes and goal', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final route = SavedRoute(
      title: 'Бег',
      distance: '5 км',
      duration: '30 мин',
      surfaceSummary: '',
      finishPoint: const LatLng(55, 83),
      routePoints: const [],
      activityType: activity.ActivityType.running,
      distanceMeters: 5000,
      durationSeconds: 1800,
      workoutDetails: const WorkoutDetails(
        goal: WorkoutGoal(WorkoutGoalKind.distance, 5000),
        elapsedSeconds: 1900,
        notes: 'Хорошая тренировка',
        effort: 5,
        samples: [
          WorkoutSample(activeSeconds: 10, distanceMeters: 20, speedKmh: 8),
          WorkoutSample(activeSeconds: 20, distanceMeters: 45, speedKmh: 9),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: WorkoutAnalytics(route: route)),
        ),
      ),
    );
    expect(find.text('Хорошая тренировка'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Countdown can be cancelled before any session starts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => const RideCountdown(),
            ),
            child: const Text('Старт'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Старт'));
    await tester.pump();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.text('Приготовьтесь'), findsNothing);
  });

  testWidgets(
    'Training HUD fits a small screen and displays monotonic active time',
    (tester) async {
      final clock = TrainingClock();
      final controller = MapNavigationController(activeClock: clock)
        ..startWorkout();
      clock.advance(95);
      controller.pauseWorkout();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: WorkoutStatsBottomSheet(
                controller: controller,
                savedRoutesRepo: SavedRoutesRepository(),
                onPauseResumePressed: () {},
                onFinishPressed: () {},
                isPaused: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('01:35'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
