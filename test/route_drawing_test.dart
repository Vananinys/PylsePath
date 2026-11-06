import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/route_edit_state.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/services/routing_service.dart';
import 'package:pulsepath/data/navigation_preferences.dart';
import 'package:pulsepath/data/saved_routes_repository.dart';
import 'package:pulsepath/screens/route_geometry_editor_screen.dart';
import 'package:pulsepath/utils/drawn_route_geometry.dart';
import 'package:pulsepath/widgets/route_drawing_layer.dart';

import 'support/main_map_test_host.dart';
import 'support/load_ui_fonts.dart';

import 'package:pulsepath/ui/app_theme.dart';

class _Roads extends RoutingService {
  bool fail = false;
  ActivityType? lastActivity;
  @override
  Future<RoutingResult> buildRoute({
    required LatLng start,
    required LatLng end,
    required ActivityType activity,
    List<LatLng> via = const [],
  }) async {
    lastActivity = activity;
    if (fail) throw const RoutingException('offline');
    return RoutingResult(
      points: [
        start,
        LatLng(start.latitude + .001, start.longitude + .001),
        end,
      ],
      steps: [],
      distanceKm: .3,
      durationMin: 5,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadUiFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SavedRoutesRepository.resetInstancesForTesting();
  });
  test('Smoothing retains endpoints, bounds and the original gesture', () {
    final raw = [const Offset(0, 0), const Offset(40, 0), const Offset(40, 40)];
    final before = List<Offset>.of(raw);
    final smooth = smoothDrawnStroke(raw);
    expect(raw, before);
    expect(smooth.first, raw.first);
    expect(smooth.last, raw.last);
    expect(smooth.length, greaterThan(raw.length));
    expect(
      smooth.every((p) => p.dx >= 0 && p.dx <= 40 && p.dy >= 0 && p.dy <= 40),
      isTrue,
    );
    expect(() => smooth.clear(), throwsUnsupportedError);
  });
  test('Appending strokes preserves gaps and does not carry ride metrics', () {
    final original = RouteEditState(const [LatLng(55, 83), LatLng(55.001, 83)]);
    final next = original.appendStroke(const [
      LatLng(56, 84),
      LatLng(56.001, 84),
    ], connect: false);
    expect(next.starts, [0, 2]);
    expect(next.meters, lessThan(300));
    expect(original.points, hasLength(2));
    final copy = next.plannedCopy(
      title: 'Рисунок',
      activity: ActivityType.cycling,
    );
    expect(copy.workoutDetails.segmentStarts, [0, 2]);
    expect(copy.durationSeconds, 0);
    expect(next.estimatedSeconds, isNull);
    expect(
      () => original.appendStroke(const [], connect: true),
      throwsFormatException,
    );
  });
  test(
    'Control extraction retains a sharp turn rather than uniform samples',
    () {
      final points = [
        for (var i = 0; i < 50; i++) LatLng(55, 83 + i * .0001),
        const LatLng(55.01, 83.005),
        for (var i = 0; i < 50; i++) LatLng(55, 83.005 + i * .0001),
      ];
      final controls = RouteEditState(points).controlPoints();
      expect(controls.points, contains(points[50]));
      expect(controls.points.first, points.first);
      expect(controls.points.last, points.last);
      expect(controls.points, hasLength(10));
    },
  );
  testWidgets(
    'Road proposal can be rejected, accepted, undone and fail without losing the source',
    (tester) async {
      final old = NavigationPreferences.instance.cachedMapOnly;
      NavigationPreferences.instance.cachedMapOnly = true;
      addTearDown(() => NavigationPreferences.instance.cachedMapOnly = old);
      final roads = _Roads();
      final original = SavedRoute(
        title: 'Оригинал',
        distance: '1 км',
        duration: '5 мин',
        surfaceSummary: '',
        finishPoint: const LatLng(55.002, 83),
        routePoints: const [LatLng(55, 83), LatLng(55.002, 83)],
        activityType: ActivityType.running,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MainMapTestHost(
            child: RouteGeometryEditorScreen(
              source: original,
              routingService: roads,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> propose() async {
        await tester.ensureVisible(find.text('Предложить путь по дорогам'));
        await tester.tap(find.text('Предложить путь по дорогам'));
        await tester.pumpAndSettle();
      }

      await propose();
      expect(roads.lastActivity, ActivityType.running);
      expect(find.text('Предпросмотр пути по дорогам'), findsOneWidget);
      await tester.ensureVisible(find.text('Оставить исходную линию'));
      await tester.tap(find.text('Оставить исходную линию'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 точек'), findsOneWidget);
      await propose();
      await tester.ensureVisible(find.text('Применить маршрут'));
      await tester.tap(find.text('Применить маршрут'));
      await tester.pumpAndSettle();
      expect(find.textContaining('3 точек'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Отменить изменение').first);
      await tester.tap(find.byTooltip('Отменить изменение').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('2 точек'), findsOneWidget);
      roads.fail = true;
      await propose();
      expect(find.textContaining('2 точек'), findsOneWidget);
      expect(find.text('Предпросмотр пути по дорогам'), findsNothing);
      expect(original.routePoints, hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'A drawn route saves independently without recording workout metrics',
    (tester) async {
      final old = NavigationPreferences.instance.cachedMapOnly;
      NavigationPreferences.instance.cachedMapOnly = true;
      addTearDown(() => NavigationPreferences.instance.cachedMapOnly = old);
      bool? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: MainMapTestHost(
            child: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () async {
                    saved = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const RouteGeometryEditorScreen(),
                      ),
                    );
                  },
                  child: const Text('Создать маршрут'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Создать маршрут'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Рисовать'));
      await tester.tap(find.text('Рисовать'));
      await tester.pumpAndSettle();
      final top = tester.getRect(find.byType(FlutterMap)).topLeft;
      final gesture = await tester.startGesture(top + const Offset(55, 180));
      await gesture.moveTo(top + const Offset(110, 200));
      await tester.pump(const Duration(milliseconds: 40));
      await gesture.moveTo(top + const Offset(180, 180));
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Добавить линию'));
      await tester.tap(find.text('Добавить линию'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Сохранить отдельный маршрут'));
      await tester.tap(find.text('Сохранить отдельный маршрут'));
      await tester.pumpAndSettle();
      expect(saved, isTrue);
      final repository = SavedRoutesRepository();
      await repository.load();
      expect(repository.savedRoutes, hasLength(1));
      final route = repository.savedRoutes.single;
      expect(route.routePoints.length, greaterThan(2));
      expect(route.durationSeconds, 0);
      expect(route.calories, 0);
      expect(route.navigationSteps, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final large in [false, true]) {
    testWidgets('Draw, preview, accept and undo on primary map; large=$large', (
      tester,
    ) async {
      final old = NavigationPreferences.instance.cachedMapOnly;
      NavigationPreferences.instance.cachedMapOnly = true;
      addTearDown(() => NavigationPreferences.instance.cachedMapOnly = old);
      tester.view.physicalSize = large
          ? const Size(320, 640)
          : const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: pulsePathTheme(
              brightness: large ? Brightness.dark : Brightness.light,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(large ? 2 : 1)),
              child: child!,
            ),
            home: const MainMapTestHost(child: RouteGeometryEditorScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Рисовать'));
      await tester.tap(find.text('Рисовать'));
      await tester.pumpAndSettle();
      expect(find.byType(RouteDrawingLayer), findsOneWidget);
      final camera = tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .mapController!
          .camera;
      final center = camera.center;
      final top = tester.getRect(find.byType(FlutterMap)).topLeft;
      final gesture = await tester.startGesture(
        top + Offset(55, large ? 300 : 245),
      );
      for (final p in [
        Offset(95, large ? 280 : 220),
        Offset(150, large ? 300 : 235),
        Offset(205, large ? 325 : 265),
      ]) {
        await gesture.moveTo(top + p);
        await tester.pump(const Duration(milliseconds: 40));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Предпросмотр рисунка'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.undo_rounded),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .mapController!
            .camera
            .center,
        center,
      );
      final dir = Platform.environment['ROUTE_EDITOR_QA_DIR'];
      if (dir != null) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(dir).create(recursive: true);
          await File('$dir/route-drawing-${large ? "large-dark" : "light"}.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.ensureVisible(find.text('Добавить линию'));
      await tester.tap(find.text('Добавить линию'));
      await tester.pumpAndSettle();
      expect(find.text('Предпросмотр рисунка'), findsNothing);
      expect(find.textContaining('0 точек'), findsNothing);
      await tester.ensureVisible(find.byTooltip('Отменить изменение').first);
      await tester.tap(find.byTooltip('Отменить изменение').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('0 точек'), findsOneWidget);
      final multiStart = top + Offset(60, large ? 300 : 245);
      final firstFinger = await tester.startGesture(multiStart, pointer: 11);
      await firstFinger.moveBy(const Offset(30, 0));
      await tester.pump();
      final secondFinger = await tester.startGesture(
        multiStart + const Offset(50, 0),
        pointer: 12,
      );
      await firstFinger.moveBy(const Offset(20, 0));
      await secondFinger.up();
      await firstFinger.up();
      await tester.pumpAndSettle();
      expect(find.text('Предпросмотр рисунка'), findsNothing);
      expect(find.textContaining('0 точек'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
