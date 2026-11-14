import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/saved_routes_repository.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/screens/route_builder_screen.dart';
import 'package:pulsepath/services/routing_service.dart';
import 'package:pulsepath/ui/app_theme.dart';

import 'support/main_map_test_host.dart';
import 'support/load_ui_fonts.dart';

class Roads extends RoutingService {
  final requests = <List<LatLng>>[];
  bool fail = false;
  @override
  Future<RoutingResult> buildRoute({
    required LatLng start,
    required LatLng end,
    ActivityType activity = ActivityType.cycling,
    List<LatLng> via = const [],
  }) async {
    requests.add([start, ...via, end]);
    if (fail) throw const RoutingException('Тестовая ошибка сети');
    return RoutingResult(
      points: [
        start,
        for (var i = 0; i < 15; i++) LatLng(55.751 + i * .0001, 37.611),
        ...via,
        end,
      ],
      steps: const [],
      distanceKm: 2,
      durationMin: 12,
    );
  }
}

void main() {
  setUpAll(loadUiFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SavedRoutesRepository.resetInstancesForTesting();
  });
  Future<void> open(
    WidgetTester tester,
    Roads roads, {
    double scale = 1,
    Brightness brightness = Brightness.light,
    SavedRoute? source,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: pulsePathTheme(brightness: brightness),
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: MainMapTestHost(
          child: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => Navigator.push(
                  ctx,
                  MaterialPageRoute(
                    builder: (_) => RouteBuilderScreen(
                      routingService: roads,
                      source: source,
                    ),
                  ),
                ),
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
  }

  Future<void> point(WidgetTester tester, Offset offset) async {
    final rect = tester.getRect(find.byType(FlutterMap));
    await tester.tapAt(rect.topLeft + offset);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'road edits use stops, save exits map and planner, source geometry does not become stops',
    (tester) async {
      final roads = Roads();
      await open(tester, roads);
      await point(tester, const Offset(130, 245));
      await point(tester, const Offset(230, 270));
      expect(roads.requests.single.length, 2);
      await point(tester, const Offset(300, 290));
      expect(roads.requests.last.length, 3);
      expect(roads.requests.last.last, roads.requests.first.last);
      await tester.tap(find.byTooltip('Отменить').first);
      await tester.pumpAndSettle();
      expect(roads.requests.last.length, 2);
      await tester.tap(find.text('Сохранить план маршрута').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.text('Открыть'), findsOneWidget);
      final repo = SavedRoutesRepository();
      await repo.load();
      expect(repo.savedRoutes.length, 1);
      expect(repo.savedRoutes.single.durationSeconds, 720);
      expect(repo.savedRoutes.single.calories, 0);
      expect(repo.savedRoutes.single.planningPoints, hasLength(2));
      final saved = SavedRoute.fromJson(repo.savedRoutes.single.toJson());
      expect(saved.planningLabels, hasLength(2));
      expect(saved.routePoints.length, greaterThan(10));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await open(tester, roads, source: saved);
      expect(find.text('Найти адрес или место').first, findsOneWidget);
      expect(find.text('Рисовать'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'draft restores stops and failed routing cannot save an unverified line',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'route_planner_draft_v1_guest': jsonEncode({
          'points': [
            [55.75, 37.61],
            [55.76, 37.62],
          ],
          'labels': ['Дом', 'Парк'],
          'roads': true,
          'activity': 'cycling',
        }),
      });
      final roads = Roads()..fail = true;
      await open(tester, roads);
      await tester.tap(find.text('Продолжить черновик').first);
      await tester.pumpAndSettle();
      expect(roads.requests.single.length, 2);
      expect(
        tester
            .widget<FilledButton>(
              find
                  .widgetWithText(FilledButton, 'Сохранить план маршрута')
                  .first,
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('Повторить построение').first);
      roads.fail = false;
      await tester.tap(find.text('Повторить построение').first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find
                  .widgetWithText(FilledButton, 'Сохранить план маршрута')
                  .first,
            )
            .onPressed,
        isNotNull,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        (jsonDecode(prefs.getString('route_planner_draft_v1_guest')!)['points']
                as List)
            .length,
        2,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final brightness in Brightness.values) {
    testWidgets('320px 200% $brightness keeps save visible', (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await open(tester, Roads(), scale: 2, brightness: brightness);
      final save = tester.getRect(find.text('Сохранить план маршрута').first);
      expect(save.bottom, lessThanOrEqualTo(740));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Развернуть панель'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('build/route_planner_qa')
          ..createSync(recursive: true);
        File('${dir.path}/${brightness.name}.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    });
  }
}
