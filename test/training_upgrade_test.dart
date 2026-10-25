import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/data/saved_routes_repository.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/interval_plan.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/shared_route.dart';
import 'package:pulsepath/models/workout_details.dart';
import 'package:pulsepath/screens/saved_routes_screen.dart';
import 'package:pulsepath/screens/training_center_screen.dart';
import 'package:pulsepath/services/distance_laps.dart';
import 'package:pulsepath/services/route_library.dart';
import 'package:pulsepath/services/routing_service.dart';
import 'package:pulsepath/services/training_insights.dart';
import 'package:pulsepath/utils/gpx_utils.dart';
import 'package:pulsepath/widgets/interval_training.dart';
import 'package:pulsepath/widgets/track_privacy_picker.dart';

import 'workout_training_test.dart' show TrainingClock;

SavedRoute activity(
  String id,
  DateTime at, {
  double km = 10,
  int minutes = 30,
  ActivityType sport = ActivityType.cycling,
  int? effort,
  List<LatLng>? points,
  WorkoutDetails? details,
}) => SavedRoute(
  localId: id,
  title: 'Лесной маршрут $id',
  createdAt: at,
  distance: '$km км',
  duration: '$minutes мин',
  distanceMeters: km * 1000,
  durationSeconds: minutes * 60,
  finishPoint: (points ?? const [LatLng(55, 83)]).last,
  routePoints: points ?? const [LatLng(55, 83), LatLng(55.01, 83.01)],
  activityType: sport,
  surfaceSummary: '',
  workoutDetails: details ?? WorkoutDetails(effort: effort),
);

class TestPlanner extends RoutingService {
  bool fail = false;
  List<LatLng> lastVia = [];
  @override
  Future<RoutingResult> buildRoute({
    required LatLng start,
    required LatLng end,
    required ActivityType activity,
    List<LatLng> via = const [],
  }) async {
    lastVia = List.of(via);
    if (fail) throw StateError('offline');
    return RoutingResult(
      points: [start, ...via, end],
      steps: [],
      distanceKm: 3,
      durationMin: 10,
      viaOffsetsMeters: [for (var i = 0; i < via.length; i++) (i + 1) * 1000.0],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final icons = File(
      'C:/src/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    );
    if (await icons.exists()) {
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(ByteData.sublistView(await icons.readAsBytes())),
          ))
          .load();
    }
    final windows = Platform.environment['WINDIR'];
    if (windows != null) {
      final font = File('$windows/Fonts/arial.ttf');
      if (await font.exists()) {
        await (FontLoader('Roboto')..addFont(
              Future.value(ByteData.sublistView(await font.readAsBytes())),
            ))
            .load();
      }
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkoutHistoryRepository.resetInstancesForTesting();
    SavedRoutesRepository.resetInstancesForTesting();
  });

  test('Weekly comparison uses the same local weekday and excludes future activities and driving', () {
    final now = DateTime(2026, 1, 1, 12);
    final data = TrainingInsights([
      activity('now', DateTime(2025, 12, 30), km: 20, effort: 4),
      activity('previous', DateTime(2025, 12, 23), km: 12),
      activity('later-in-previous-week', DateTime(2025, 12, 26), km: 50),
      activity('future', DateTime(2026, 1, 2), km: 100),
      activity(
        'car',
        DateTime(2025, 12, 31),
        km: 1000,
        sport: ActivityType.driving,
      ),
    ], now: now);
    expect(data.thisWeek.km, 20);
    expect(data.previousWeekToDate.km, 12);
    expect(data.thisWeek.effortLoad, 120);
    expect(data.thisWeek.effortCount, 1);
    expect(data.thisWeek.activeDays, 1);
    expect(data.consecutiveWeeks, 2);
    expect(data.weeks, hasLength(8));
    expect(data.weeks.last.totals.km, 20);
  });

  test('Sport filters group foot activities separately and never estimate missing effort', () {
    final now = DateTime(2026, 10, 19, 12);
    final data = TrainingInsights(
      [
        activity('run', now, sport: ActivityType.trailRunning),
        activity('walk', now, sport: ActivityType.briskWalking),
        activity('bike', now, sport: ActivityType.roadCycling),
      ],
      sport: TrainingSport.running,
      now: now,
    );
    expect(data.thisWeek.count, 1);
    expect(data.thisWeek.effortCount, 0);
    expect(data.thisWeek.effortLoad, 0);
    expect(data.onDay(now).single.localId, 'run');
  });

  test('Automatic distance laps interpolate boundaries once and continue after recovery', () {
    final laps = DistanceLaps(1000);
    laps.update(900, const Duration(seconds: 90));
    final first = laps.update(1100, const Duration(seconds: 110));
    expect(first.single.endSeconds, 100);
    expect(first.single.distanceMeters, 1000);
    expect(laps.update(1100, const Duration(seconds: 110)), isEmpty);
    final restored = DistanceLaps(1000, completed: laps.laps)
      ..seed(1500, const Duration(seconds: 150));
    expect(
      restored.update(2100, const Duration(seconds: 210)).single.activeSeconds,
      100,
    );
    expect(restored.update(2000, const Duration(seconds: 220)), isEmpty);
    expect(DistanceLaps(0).update(5000, const Duration(seconds: 500)), isEmpty);
  });

  test(
    'Interval phase boundaries, completion and persisted metadata remain exact',
    () {
      const plan = IntervalPlan(
        warmup: 60,
        work: 30,
        recovery: 20,
        repeats: 2,
        cooldown: 40,
      );
      expect(plan.totalSeconds, 180);
      expect(plan.phaseAt(59)!.label, 'Разминка');
      expect(plan.phaseAt(60)!.repeat, 1);
      expect(plan.phaseAt(90)!.label, 'Восстановление');
      expect(plan.phaseAt(110)!.repeat, 2);
      expect(plan.phaseAt(140)!.label, 'Заминка');
      expect(plan.phaseAt(180), isNull);
      expect(IntervalPlan.fromJson({...plan.toJson(), 'repeats': 0}), isNull);
      final restored = WorkoutDetails.fromJson(
        jsonDecode(
          jsonEncode(
            const WorkoutDetails(
              intervalPlan: plan,
              autoLapMeters: 1000,
              autoLaps: [
                WorkoutLap(
                  number: 1,
                  distanceMeters: 1000,
                  activeSeconds: 90,
                  endSeconds: 90,
                ),
              ],
            ).toJson(),
          ),
        ),
      );
      expect(restored.intervalPlan!.totalSeconds, 180);
      expect(restored.autoLaps.single.activeSeconds, 90);
      final clock = TrainingClock();
      final c = MapNavigationController(activeClock: clock)
        ..setIntervalPlan(plan)
        ..setAutoPauseEnabled(false)
        ..startWorkout();
      clock.advance(75);
      c.pauseWorkout();
      clock.advance(300);
      expect(c.intervalPhase!.remaining(c.activeWorkoutDuration.inSeconds), 15);
      c.resumeWorkout();
      clock.advance(16);
      expect(c.intervalPhase!.label, 'Восстановление');
      c.dispose();
    },
  );

  test(
    'Hidden start and finish coordinates are absent from both snapshot and GPX',
    () {
      final points = List.generate(81, (i) => LatLng(55 + i * .0001, 83));
      final source = activity('privacy', DateTime(2026), points: points);
      final shared = SharedRoute.fromSavedRoute(source, hideRadiusMeters: 200);
      const distance = Distance();
      expect(shared.points.length, greaterThan(2));
      for (final p in shared.points) {
        expect(distance(points.first, p), greaterThanOrEqualTo(200));
        expect(distance(points.last, p), greaterThanOrEqualTo(200));
      }
      final gpx = GpxUtils.build(
        points: shared.points,
        segmentStarts: shared.segmentStarts,
      );
      expect(gpx.contains('lat="55.000000"'), isFalse);
      expect(
        SharedRoute.tryParse(shared.toJson())!.points.length,
        shared.points.length,
      );
      expect(
        SharedRoute.fromSavedRoute(source, hideRadiusMeters: 5000).points,
        isEmpty,
      );
      expect(source.routePoints.length, 81);
    },
  );

  test('GPX import and navigation keep real gaps and exclude unknown connecting distance', () {
    const points = [
      LatLng(55, 83),
      LatLng(55.001, 83),
      LatLng(56, 83),
      LatLng(56.001, 83),
    ];
    final xml = GpxUtils.build(
      points: points,
      name: 'Два участка',
      segmentStarts: [0, 2],
    );
    final parsed = GpxUtils.parseTrack(xml);
    expect(parsed.segmentStarts, [0, 2]);
    expect(parsed.name, 'Два участка');
    final c = MapNavigationController();
    expect(
      c.loadImportedTrack(parsed.points, segmentStarts: parsed.segmentStarts),
      isTrue,
    );
    expect(c.routeSegments.map((s) => s.length), [2, 2]);
    expect(c.routeDistanceKm, closeTo(.2224, .002));
    expect(c.routeSteps.first.instruction, contains('разрыв'));
    c.dispose();
    final invalid = GpxUtils.parseTrack(
      '<gpx><trk><trkseg><trkpt lat="55" lon="83"/><trkpt lat="999" lon="83"/><trkpt lat="56" lon="83"/></trkseg></trk></gpx>',
    );
    expect(invalid.segmentStarts, [0, 1]);
  });

  test('Library edits preserve telemetry and persist with favorites, collection and stop points', () async {
    final route = activity('library', DateTime(2026), effort: 7)
        .withLibraryDetails(
          favorite: true,
          collection: 'Выходные',
          notes: 'Кофе на финише',
        );
    final repo = SavedRoutesRepository();
    await repo.addRoute(route);
    await repo.updateRoute(route.withLibraryDetails(title: 'Лес и озеро'));
    final restored = (await repo.getSavedRoutes()).single;
    expect(restored.isFavorite, isTrue);
    expect(restored.workoutDetails.effort, 7);
    expect(restored.withSyncState(cloudSynced: true).collection, 'Выходные');
    expect(
      filterRoutes([restored], query: 'озеро кофе', favorites: true),
      hasLength(1),
    );
    expect(filterRoutes([restored], maxKm: 5), isEmpty);
  });

  test('Waypoint planning commits only a successful route and keeps previous route after failure', () async {
    final planner = TestPlanner();
    final c = MapNavigationController(routingService: planner);
    c.setFinishPoint(const LatLng(55.02, 83), 'Финиш');
    expect(c.canEditWaypoints, isFalse);
    await c.buildRoute();
    const stop = LatLng(55.01, 83);
    await c.replanWithWaypoints([stop]);
    expect(c.routeWaypoints, [stop]);
    expect(c.routePoints.length, 3);
    planner.fail = true;
    await expectLater(c.replanWithWaypoints([]), throwsStateError);
    expect(c.routeWaypoints, [stop]);
    expect(c.routePoints.length, 3);
    expect(c.isLoadingRoute, isFalse);
    expect(c.routeError, contains('Предыдущий маршрут'));
    c.dispose();
  });

  testWidgets('Calendar, trends and route library work on a narrow phone', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ride = activity(
      'Вечер',
      DateTime.now().subtract(const Duration(minutes: 5)),
      effort: 4,
    );
    await WorkoutHistoryRepository().addWorkout(ride);
    final preview = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorSchemeSeed: Colors.deepOrange,
        ),
        home: RepaintBoundary(
          key: preview,
          child: const TrainingCenterScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Тренировочный центр'), findsOneWidget);
    expect(find.text('10.0 км'), findsWidgets);
    expect(tester.takeException(), isNull);
    await _capture(tester, preview, 'training-center');
    await tester.scrollUntilVisible(
      find.text('Личные ориентиры'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await SavedRoutesRepository().addRoute(ride);
    final libraryPreview = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorSchemeSeed: Colors.deepOrange,
        ),
        home: RepaintBoundary(
          key: libraryPreview,
          child: const SavedRoutesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(ride.title), findsOneWidget);
    await _capture(tester, libraryPreview, 'route-library');
    await tester.tap(find.byTooltip('В избранное'));
    await tester.pumpAndSettle();
    expect(
      (await SavedRoutesRepository().getSavedRoutes()).single.isFavorite,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), 'несуществующий');
    await tester.pumpAndSettle();
    expect(find.text('Маршрутов с такими условиями нет'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Interval configuration and privacy controls fit narrow screens',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = MapNavigationController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: IntervalSetup(controller: c)),
          ),
        ),
      );
      await tester.tap(find.text('Интервальная тренировка'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Применить'));
      await tester.pumpAndSettle();
      expect(c.intervalPlan!.repeats, 5);
      final route = activity('privacy', DateTime(2026));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TrackPrivacyPicker(
                route: route,
                enabled: true,
                radius: 200,
                onEnabled: (_) {},
                onRadius: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      c.dispose();
    },
  );
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final picture = await boundary.toImage(pixelRatio: 2);
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    final folder = Directory('build/previews')..createSync(recursive: true);
    await File('${folder.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    picture.dispose();
  });
}
