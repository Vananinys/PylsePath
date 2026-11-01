import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/widgets/primary_map_portal.dart';
import 'package:pulsepath/screens/group_meeting_editor.dart';
import 'package:pulsepath/models/group_coordination.dart';
import 'package:pulsepath/screens/route_builder_screen.dart';
import 'package:pulsepath/data/saved_routes_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Primary map task remains usable on a narrow phone at 200%', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = MapController();
    var selected = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Stack(
              children: [
                PrimaryMapPortal(
                  controller: controller,
                  onOpen: () {},
                  child: FlutterMap(
                    mapController: controller,
                    options: MapOptions(
                      onTap: PrimaryMapNavigation.instance.tap,
                    ),
                    children: const [
                      SizedBox.expand(child: ColoredBox(color: Colors.white)),
                      PrimaryMapTaskLayers(),
                    ],
                  ),
                ),
                Positioned(
                  top: 24,
                  left: 12,
                  child: FilledButton(
                    onPressed: () => PrimaryMapNavigation.instance.open(
                      context,
                      title: 'Место встречи и остановки',
                      config: () => FlutterMap(
                        options: MapOptions(
                          onTap: (_, point) => selected = true,
                        ),
                        children: const [],
                      ),
                    ),
                    child: const Text('Место'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Место'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final zoom = controller.camera.zoom;
    await tester.tap(find.byTooltip('Приблизить'));
    await tester.pumpAndSettle();
    expect(controller.camera.zoom, zoom + 1);
    final top = tester.getBottomLeft(find.text('Основная карта')).dy;
    final bottom = tester
        .getTopLeft(
          find.textContaining('Нажмите на карте, чтобы выбрать точку.'),
        )
        .dy;
    expect(bottom - top, greaterThan(40));
    await tester.tapAt(Offset(140, (top + bottom) / 2));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets(
    'Point task moves the same map state and preserves the source form',
    (tester) async {
      final controller = MapController();
      LatLng? picked;
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Stack(
                children: [
                  PrimaryMapPortal(
                    controller: controller,
                    onOpen: () => opened++,
                    child: FlutterMap(
                      mapController: controller,
                      options: MapOptions(
                        initialCenter: const LatLng(0, 0),
                        initialZoom: 12,
                        onTap: PrimaryMapNavigation.instance.tap,
                      ),
                      children: const [PrimaryMapTaskLayers()],
                    ),
                  ),
                  Positioned(
                    top: 24,
                    left: 16,
                    child: FilledButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => StatefulBuilder(
                            builder: (context, setState) => Scaffold(
                              appBar: AppBar(
                                title: const Text('Исходная форма'),
                              ),
                              body: Column(
                                children: [
                                  Text(
                                    picked == null
                                        ? 'Точка не выбрана'
                                        : 'Точка сохранена в форме',
                                  ),
                                  Expanded(
                                    child: MainMapGateway(
                                      controls: (context) => TextButton(
                                        onPressed: () =>
                                            PrimaryMapNavigation.instance.open(
                                              context,
                                              title: 'Вложенный просмотр',
                                              config: () => FlutterMap(
                                                children: const [],
                                                options: const MapOptions(
                                                  initialCenter: LatLng(1, 1),
                                                ),
                                              ),
                                            ),
                                        child: const Text('Другой участок'),
                                      ),
                                      title: 'Где остановимся?',
                                      map: FlutterMap(
                                        options: MapOptions(
                                          initialCenter: const LatLng(0, 0),
                                          initialZoom: 12,
                                          onTap: (_, point) =>
                                              setState(() => picked = point),
                                        ),
                                        children: [
                                          if (picked != null)
                                            MarkerLayer(
                                              markers: [
                                                Marker(
                                                  point: picked!,
                                                  child: const Icon(Icons.flag),
                                                ),
                                              ],
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      child: const Text('Открыть форму'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initialMap = tester.state(find.byType(FlutterMap));
      expect(PrimaryMapNavigation.instance.active, isFalse);
      await tester.tap(find.text('Открыть форму'));
      await tester.pumpAndSettle();
      expect(find.byType(FlutterMap, skipOffstage: false), findsOneWidget);
      await tester.tap(find.text('На основной карте'));
      await tester.pumpAndSettle();
      expect(find.byType(FlutterMap, skipOffstage: false), findsOneWidget);
      expect(
        identical(tester.state(find.byType(FlutterMap)), initialMap),
        isTrue,
      );
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(picked, isNotNull);
      expect(find.byIcon(Icons.flag), findsOneWidget);
      await tester.tap(find.text('Другой участок'));
      await tester.pumpAndSettle();
      expect(find.text('Вложенный просмотр'), findsOneWidget);
      expect(find.byType(FlutterMap, skipOffstage: false), findsOneWidget);
      expect(
        identical(tester.state(find.byType(FlutterMap)), initialMap),
        isTrue,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Где остановимся?'), findsOneWidget);
      expect(find.byIcon(Icons.flag), findsOneWidget);
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(find.text('Точка сохранена в форме'), findsOneWidget);
      expect(find.byType(FlutterMap, skipOffstage: false), findsOneWidget);
      expect(opened, 2);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('На основной карте'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(PrimaryMapNavigation.instance.active, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        identical(tester.state(find.byType(FlutterMap)), initialMap),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'Stop proposal automatically uses main map and returns the chosen point',
    (tester) async {
      final controller = MapController();
      GroupMeetPlan? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Stack(
                children: [
                  PrimaryMapPortal(
                    controller: controller,
                    onOpen: () {},
                    child: FlutterMap(
                      mapController: controller,
                      options: MapOptions(
                        initialCenter: const LatLng(0, 0),
                        onTap: PrimaryMapNavigation.instance.tap,
                      ),
                      children: const [PrimaryMapTaskLayers()],
                    ),
                  ),
                  Positioned(
                    top: 24,
                    left: 12,
                    child: FilledButton(
                      onPressed: () async {
                        result = await Navigator.push<GroupMeetPlan>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const GroupMeetingEditor(
                              initial: GroupMeetPlan(),
                              center: LatLng(0, 0),
                              pointOnly: true,
                              stopProposal: true,
                            ),
                          ),
                        );
                      },
                      child: const Text('Остановка'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initialMap = tester.state(find.byType(FlutterMap));
      await tester.tap(find.text('Остановка'));
      await tester.pumpAndSettle();
      expect(find.text('Основная карта'), findsOneWidget);
      expect(find.byType(FlutterMap, skipOffstage: false), findsOneWidget);
      expect(
        identical(tester.state(find.byType(FlutterMap)), initialMap),
        isTrue,
      );
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Вода у фонтана');
      await tester.ensureVisible(find.text('Предложить группе'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Предложить группе'));
      await tester.pumpAndSettle();
      expect(result?.point, isNotNull);
      expect(result?.label, 'Вода у фонтана');
      expect(
        identical(tester.state(find.byType(FlutterMap)), initialMap),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'Route editor adds and undoes points on the main map, then saves its copy',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = MapController();
      bool? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Stack(
                children: [
                  PrimaryMapPortal(
                    controller: controller,
                    onOpen: () {},
                    child: FlutterMap(
                      mapController: controller,
                      options: MapOptions(
                        initialCenter: const LatLng(0, 0),
                        onTap: PrimaryMapNavigation.instance.tap,
                      ),
                      children: const [PrimaryMapTaskLayers()],
                    ),
                  ),
                  Positioned(
                    top: 24,
                    left: 12,
                    child: FilledButton(
                      onPressed: () async {
                        saved = await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const RouteBuilderScreen(
                              initialCenter: LatLng(0, 0),
                            ),
                          ),
                        );
                      },
                      child: const Text('Маршрут'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initialMap = tester.state(find.byType(FlutterMap));
      await tester.tap(find.text('Маршрут'));
      await tester.pumpAndSettle();
      for (final point in [const Offset(380, 190), const Offset(420, 220)]) {
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
      }
      expect(find.textContaining('2 точек'), findsOneWidget);
      await tester.tap(find.byTooltip('Отменить изменение').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('1 точек'), findsOneWidget);
      await tester.tap(find.byTooltip('Повторить изменение').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('2 точек'), findsOneWidget);
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Сохранить отдельный маршрут'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить отдельный маршрут'));
      await tester.pumpAndSettle();
      expect(saved, isTrue);
      final repository = SavedRoutesRepository();
      await repository.load();
      expect(repository.savedRoutes, hasLength(1));
      expect(repository.savedRoutes.single.routePoints, hasLength(2));
      expect(
        identical(tester.state(find.byType(FlutterMap)), initialMap),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
