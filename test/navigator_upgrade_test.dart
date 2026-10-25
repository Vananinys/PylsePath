import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/bike_equipment.dart';
import 'package:pulsepath/models/route_step.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/services/trail_guidance.dart';
import 'package:pulsepath/services/routing_service.dart';
import 'package:pulsepath/screens/ride_dashboard_screen.dart';
import 'package:pulsepath/widgets/workout_comparison.dart';

import 'workout_training_test.dart' show fix, TrainingClock;

class FailedRouting extends RoutingService {
  @override
  Future<RoutingResult> buildRoute({
    required LatLng start,
    required LatLng end,
    required ActivityType activity,
    List<LatLng> via = const [],
  }) async => throw StateError('Нет сети');
}

SavedRoute ride(
  String id,
  DateTime at, {
  double km = 10,
  int seconds = 1800,
  List<RouteStep> steps = const [],
}) => SavedRoute(
  localId: id,
  title: id,
  createdAt: at,
  distance: '$km км',
  duration: '$seconds сек',
  distanceMeters: km * 1000,
  durationSeconds: seconds,
  surfaceSummary: '',
  finishPoint: const LatLng(55, 83),
  routePoints: const [LatLng(55, 83), LatLng(55.01, 83)],
  activityType: ActivityType.cycling,
  navigationSteps: steps,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkoutHistoryRepository.resetInstancesForTesting();
  });

  test('turn instructions survive local save and sync-state copy', () {
    final step = RouteStep(
      instruction: 'Направо',
      streetName: 'Улица',
      icon: Icons.turn_right,
      location: const LatLng(55.01, 83),
      distance: 30,
      routeOffsetMeters: 200,
    );
    final restored = SavedRoute.fromJson(
      ride('a', DateTime(2026), steps: [step]).toJson(),
    ).withSyncState(cloudSynced: true);
    expect(restored.navigationSteps.single.instruction, 'Направо');
    expect(restored.navigationSteps.single.icon, Icons.turn_right);
    final c = MapNavigationController()..loadSavedRoute(restored);
    expect(c.routeSteps.single.routeOffsetMeters, 200);
    expect(c.followsSavedTrack, isTrue);
    c.dispose();
  });

  test(
    'geometric guidance identifies a turn and ends exactly at track end',
    () {
      const points = [
        LatLng(55, 83),
        LatLng(55.001, 83),
        LatLng(55.001, 83.002),
      ];
      final steps = TrailGuidance.steps(points);
      expect(steps.first.icon, Icons.turn_right);
      expect(steps.last.icon, Icons.flag);
      expect(
        steps.last.routeOffsetMeters,
        closeTo(TrailGuidance.length(points), .001),
      );
      expect(TrailGuidance.steps(const [LatLng(55, 83)]), isEmpty);
    },
  );

  test(
    'return along track reverses navigation without changing recorded ride',
    () {
      final c = MapNavigationController(activeClock: TrainingClock())
        ..setAutoPauseEnabled(false);
      c.startWorkout();
      final at = DateTime.now();
      for (var i = 0; i < 4; i++) {
        c.applyGpsSampleForTesting(
          fix(55 + i * .0001, at.add(Duration(seconds: i * 4))),
        );
      }
      final recorded = List<LatLng>.of(c.recordedPath);
      expect(recorded.length, greaterThanOrEqualTo(2));
      c.returnAlongTrack();
      expect(c.routePoints, recorded.reversed.toList());
      expect(c.recordedPath, recorded);
      expect(c.isNavigating, isTrue);
      expect(c.followsSavedTrack, isTrue);
      c.dispose();
    },
  );

  test('return path never bridges a GPS gap', () {
    final c = MapNavigationController()..setAutoPauseEnabled(false);
    c.startWorkout();
    final at = DateTime.now();
    for (var i = 0; i < 3; i++) {
      c.applyGpsSampleForTesting(
        fix(55 + i * .0001, at.add(Duration(seconds: i * 4))),
      );
    }
    for (var i = 0; i < 3; i++) {
      c.applyGpsSampleForTesting(
        fix(55.003 + i * .0001, at.add(Duration(seconds: 60 + i * 4))),
      );
    }
    c.returnAlongTrack();
    expect(c.routePoints.every((p) => p.latitude >= 55.003), isTrue);
    expect(c.routeNotice, contains('разрывы'));
    c.dispose();
  });

  test('road return failure retains the current navigation and ride', () async {
    final c = MapNavigationController(routingService: FailedRouting())
      ..setAutoPauseEnabled(false);
    c.startWorkout();
    final at = DateTime.now();
    for (var i = 0; i < 3; i++) {
      c.applyGpsSampleForTesting(
        fix(55 + i * .0001, at.add(Duration(seconds: i * 4))),
      );
    }
    c.returnAlongTrack();
    final oldPath = List<LatLng>.of(c.routePoints),
        recorded = List<LatLng>.of(c.recordedPath);
    await expectLater(c.returnToStartByRoads(), throwsStateError);
    expect(c.routePoints, oldPath);
    expect(c.recordedPath, recorded);
    expect(c.isNavigating, isTrue);
    expect(c.isLoadingRoute, isFalse);
    expect(c.followsSavedTrack, isTrue);
    c.dispose();
  });

  test('off-route requires repeated precise fixes and recovers near track', () {
    final c = MapNavigationController();
    c.loadSavedRoute(ride('a', DateTime(2026)));
    c.setNavigating(true);
    final at = DateTime.now();
    c.applyGpsSampleForTesting(fix(55.02, at));
    expect(c.isOffRoute, isFalse);
    c.applyGpsSampleForTesting(
      fix(55.02, at.add(const Duration(seconds: 1)), accuracy: 100),
    );
    expect(c.isOffRoute, isFalse);
    c.applyGpsSampleForTesting(fix(55.02, at.add(const Duration(seconds: 2))));
    c.applyGpsSampleForTesting(fix(55.02, at.add(const Duration(seconds: 3))));
    expect(c.isOffRoute, isTrue);
    c.applyGpsSampleForTesting(fix(55.005, at.add(const Duration(seconds: 4))));
    expect(c.isOffRoute, isFalse);
    c.dispose();
  });

  test(
    'calendar service interval can expire before mileage and survives JSON',
    () {
      final part = BikePart(
        id: 'chain',
        name: 'Цепь',
        intervalKm: 500,
        lastServiceKm: 100,
        intervalDays: 30,
        lastServiceAt: DateTime(2026, 9, 1),
      );
      expect(part.due(110, now: DateTime(2026, 9, 30, 23)), isFalse);
      expect(part.due(110, now: DateTime(2026, 10, 1)), isTrue);
      final restored = BikePart.fromJson(part.toJson());
      expect(restored.copyWith(lastServiceKm: 200).intervalDays, 30);
      expect(restored.daysRemaining(now: DateTime(2026, 10, 2)), -1);
      expect(
        BikePart.fromJson({'id': 'old', 'name': 'Старая'}).due(0),
        isFalse,
      );
    },
  );

  test('service expenses only sum valid ruble records', () {
    final part = BikePart(
      id: 'a',
      name: 'Деталь',
      history: [
        {'cost': 100, 'currency': 'RUB'},
        {'cost': 12.5, 'currency': 'RUB'},
        {'cost': 50, 'currency': 'USD'},
        {'cost': -100, 'currency': 'RUB'},
        {'note': 'Старая запись'},
      ],
    );
    expect(BikePart.fromJson(part.toJson()).serviceCostRubles, 112.5);
  });

  testWidgets('large dashboard fits narrow phone and allows locking controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = MapNavigationController()..startWorkout();
    await tester.pumpWidget(
      MaterialApp(
        home: RideDashboardScreen(controller: c, onFinish: () {}),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Заблокировать кнопки'));
    await tester.pump();
    expect(find.byTooltip('Разблокировать'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
    'comparison uses older same-activity rides and reports speed delta',
    (tester) async {
      final repo = WorkoutHistoryRepository();
      await repo.addWorkout(
        ride('previous', DateTime(2026, 10, 17), seconds: 3600),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: WorkoutComparison(
                route: ride('current', DateTime(2026, 10, 18)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('+10.0 км/ч'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
