import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/data/saved_routes_repository.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/widgets/map_home_actions.dart';
import 'package:pulsepath/widgets/map_ui_overlays.dart';
import 'package:pulsepath/widgets/pre_ride_widget.dart';
import 'package:pulsepath/widgets/ride_preparation_panel.dart';
import 'package:pulsepath/widgets/workout_stats_bottom_sheet.dart';
import 'package:pulsepath/ui/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SavedRoutesRepository.resetInstancesForTesting();
    WorkoutHistoryRepository.resetInstancesForTesting();
  });
  setUpAll(() async {
    for (final font in const {
      'Roboto': 'C:/Windows/Fonts/arial.ttf',
      'MaterialIcons': 'C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final file = File(font.value);
      if (await file.exists()) {
        await (FontLoader(
          font.key,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });

  for (final width in [320.0, 360.0]) {
    testWidgets('two main journeys remain readable at $width and large text', (
      tester,
    ) async {
      resize(tester, Size(width, 780));
      var workouts = 0, routes = 0;
      await tester.pumpWidget(
        shell(
          MapHomeActions(onWorkout: () => workouts++, onRoute: () => routes++),
          scale: 1.5,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Начать тренировку'), findsOneWidget);
      expect(find.text('Построить маршрут'), findsOneWidget);
      await tester.tap(find.text('Начать тренировку'));
      await tester.tap(find.text('Построить маршрут'));
      expect(workouts, 1);
      expect(routes, 1);
    });
  }

  testWidgets('route entry keeps search, map, library and loop accessible', (
    tester,
  ) async {
    RouteEntryAction? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showRouteEntrySheet(context);
              },
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    for (final title in [
      'Найти место',
      'Выбрать на карте',
      'Сохранённые маршруты',
      'Круговой маршрут',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    await tester.tap(find.text('Выбрать на карте'));
    await tester.pumpAndSettle();
    expect(selected, RouteEntryAction.map);
  });

  testWidgets(
    'search scope appears only on focus and names the current scope',
    (tester) async {
      resize(tester, const Size(360, 800));
      final text = TextEditingController();
      final focus = FocusNode();
      bool? scope;
      String? submitted;
      await tester.pumpWidget(
        shell(
          SearchPanel(
            searchController: text,
            focusNode: focus,
            isSearching: false,
            searchResults: const [],
            onSearchChanged: (_) {},
            onSelectResult: (_) {},
            onClearSearch: () {},
            openDrawer: () {},
            onSearchSubmitted: (q) => submitted = q,
            onSearchScopeChanged: (value) => scope = value,
          ),
        ),
      );
      expect(find.text('Рядом'), findsNothing);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.text('Рядом'), findsOneWidget);
      await tester.tap(find.byTooltip('Где искать'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckedPopupMenuItem<bool>).last);
      await tester.pumpAndSettle();
      expect(scope, false);
      await tester.enterText(find.byType(TextField), 'улица Ленина');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      expect(submitted, 'улица Ленина');
      focus.unfocus();
      await tester.pumpAndSettle();
      expect(find.text('Рядом'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      text.dispose();
      focus.dispose();
    },
  );

  testWidgets(
    'preparation reveals all optional settings without hiding start',
    (tester) async {
      resize(tester, const Size(360, 800));
      final controller = MapNavigationController();
      final key = GlobalKey();
      var starts = 0;
      await tester.pumpWidget(
        shell(
          RepaintBoundary(
            key: key,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 570),
                  child: PreRideWidget(
                    selectedVehicle: null,
                    onSelectVehicle: () {},
                    autoPauseEnabled: false,
                    onAutoPauseChanged: (_) {},
                    sportMode: SportMode.vehicle,
                    onSportModeChanged: (_) {},
                    onStartRide: () => starts++,
                    onCollapse: () {},
                    readiness: const Text('GPS готов · ±12 м'),
                    preparation: RidePreparationPanel(
                      showGps: false,
                      controller: controller,
                      onSharingChanged: (_) {},
                      onGpsRetry: () async {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Цель и интервалы'), findsNothing);
      await snapshot(tester, key, 'preparation');
      await tester.tap(find.text('Настройки тренировки'));
      await tester.pumpAndSettle();
      expect(find.text('Цель и интервалы'), findsOneWidget);
      expect(find.text('Запись и отсечки'), findsOneWidget);
      expect(find.text('Кто видит мою позицию'), findsOneWidget);
      await tester.tap(find.text('НАЧАТЬ'));
      expect(starts, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  for (final scale in [1.0, 1.5]) {
    testWidgets(
      'compact recording preserves pause, finish and full statistics at $scale',
      (tester) async {
        resize(tester, const Size(360, 800));
        final c = MapNavigationController()..startWorkout();
        final key = GlobalKey();
        var pauses = 0, finishes = 0;
        await tester.pumpWidget(
          shell(
            RepaintBoundary(
              key: key,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: WorkoutStatsBottomSheet(
                  controller: c,
                  savedRoutesRepo: SavedRoutesRepository(),
                  onPauseResumePressed: () => pauses++,
                  onFinishPressed: () => finishes++,
                ),
              ),
            ),
            scale: scale,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('средняя'), findsNothing);
        final height = tester
            .getSize(find.byType(WorkoutStatsBottomSheet))
            .height;
        // CI uses Ahem, whose glyphs are wider than the platform font. Keep
        // the map visible over most of the screen without shrinking text.
        expect(
          height,
          lessThan(
            tester.view.physicalSize.height / tester.view.devicePixelRatio / 2,
          ),
        );
        if (scale == 1) await snapshot(tester, key, 'recording');
        await tester.tap(find.text('Пауза'));
        expect(pauses, 1);
        await tester.tap(find.text('Финиш'));
        expect(finishes, 1);
        await tester.tap(find.text('Подробнее'));
        await tester.pumpAndSettle();
        expect(find.text('средняя'), findsOneWidget);
        expect(find.text('максимальная'), findsOneWidget);
        expect(find.text('набор высоты'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }
}

void resize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget shell(Widget child, {double scale = 1}) => MaterialApp(
  theme: pulsePathTheme(),
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(360, 800),
      textScaler: TextScaler.linear(scale),
    ),
    child: Scaffold(body: child),
  ),
);
Future<void> snapshot(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final picture = await boundary.toImage(pixelRatio: 2);
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/progressive-map-preview')
      ..createSync(recursive: true);
    await File('${dir.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    picture.dispose();
  });
}
