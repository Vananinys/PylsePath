import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/services/geocoding_service.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/widgets/pre_ride_widget.dart';
import 'package:pulsepath/widgets/route_details_bottom_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = {
      'Roboto': 'C:/Windows/Fonts/arial.ttf',
      'MaterialIcons': 'C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    };
    for (final entry in fonts.entries) {
      final file = File(entry.value);
      if (!await file.exists()) continue;
      final loader = FontLoader(entry.key)
        ..addFont(file.readAsBytes().then((b) => ByteData.sublistView(b)));
      await loader.load();
    }
  });
  test(
    'local search stays near GPS and another city uses a separate cache',
    () async {
      final requests = <Uri>[];
      final service = GeocodingService(
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode([
              {'lat': '52.55', 'lon': '85.22', 'display_name': 'Дальний парк'},
              {'lat': '52.53', 'lon': '85.18', 'display_name': 'Ближний парк'},
            ]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final local = await service.searchPlaces(
        'парк проверка',
        center: const LatLng(52.529, 85.18),
      );
      expect(local.first['display_name'], 'Ближний парк');
      expect(requests.single.queryParameters['bounded'], '1');
      expect(requests.single.queryParameters['accept-language'], 'ru');
      final box = requests.single.queryParameters['viewbox']!
          .split(',')
          .map(double.parse)
          .toList();
      expect(box[0], lessThan(85.18));
      expect(box[2], greaterThan(85.18));
      await service.searchPlaces(
        'парк проверка',
        center: const LatLng(56.48, 84.95),
      );
      await service.searchPlaces('парк проверка', nearbyOnly: false);
      expect(requests.length, 3);
      expect(requests.last.queryParameters.containsKey('viewbox'), isFalse);
    },
  );

  test('city and district are resolved in Russian', () async {
    final service = GeocodingService(
      client: MockClient((request) async {
        expect(request.url.path, '/reverse');
        expect(request.url.queryParameters['accept-language'], 'ru');
        return http.Response(
          jsonEncode({
            'address': {'town': 'Бийск', 'suburb': 'Заречье'},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    expect(
      await service.locality(const LatLng(52.529, 85.18)),
      'Бийск · Заречье',
    );
  });

  test(
    'starting after activity preparation preserves the planned route',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = MapNavigationController();
      controller.setSelectedActivity(ActivityType.hiking);
      controller.prepareWorkoutActivity();
      controller.setRouteForTesting(
        points: const [LatLng(52.53, 85.18), LatLng(52.54, 85.19)],
        steps: [],
      );
      controller.setNavigating(true);
      controller.startWorkout();
      expect(controller.isWorkoutActive, isTrue);
      expect(controller.routePoints, hasLength(2));
      expect(controller.isNavigating, isTrue);
      controller.dispose();
    },
  );

  for (final scale in [1.0, 1.5]) {
    testWidgets('preparation keeps start visible at text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var starts = 0;
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(360, 780),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: RepaintBoundary(
                key: key,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 540),
                      child: PreRideWidget(
                        selectedVehicle: null,
                        onSelectVehicle: () {},
                        autoPauseEnabled: true,
                        onAutoPauseChanged: (_) {},
                        sportMode: SportMode.walking,
                        onSportModeChanged: (_) {},
                        onStartRide: () => starts++,
                        onCollapse: () {},
                        routeLabel: 'Бийск, улица Ленина, 24',
                        preparation: Column(
                          children: List.generate(
                            20,
                            (i) => ListTile(
                              title: Text('Настройка тренировки $i'),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('НАЧАТЬ'));
      expect(starts, 1);
      if (scale == 1) await capture(tester, key, 'preparation');
    });

    testWidgets(
      'route start stays visible while details scroll at scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var starts = 0, navigation = 0;
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(360, 780),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: RepaintBoundary(
                  key: key,
                  child: Stack(
                    children: [
                      Container(color: const Color(0xFFE9EDE8)),
                      Positioned.fill(
                        child: RouteDetailsBottomSheet(
                          finishAddress: 'Бийск, улица Ленина, 24',
                          finishPoint: const LatLng(52.53, 85.18),
                          selectedActivity: ActivityType.cycling,
                          activityTypes: ActivityType.values,
                          routeDistanceKm: 4.2,
                          routeDurationMin: 21,
                          elevationGainMeters: 0,
                          elevationLossMeters: 0,
                          surfaceInfo: null,
                          isLoadingRoute: false,
                          isBookmarked: false,
                          isNavigating: false,
                          onClearRoute: () {},
                          onActivityChanged: (_) {},
                          onToggleBookmark: () {},
                          onShareRoute: () {},
                          onToggleNavigation: () => navigation++,
                          onStartWorkout: () => starts++,
                          formatDuration: (_) => '21 мин',
                          formatETA: (_) => 'до 19:41',
                          calculateCalories: () => 126,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Начать тренировку'));
        expect(starts, 1);
        expect(navigation, 0);
        await tester.tap(find.text('Только навигация'));
        expect(navigation, 1);
        if (scale == 1) await capture(tester, key, 'route');
      },
    );
  }
}

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final picture = await boundary.toImage(pixelRatio: 2);
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/route-refresh-preview')
      ..createSync(recursive: true);
    await File('${dir.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    picture.dispose();
  });
}
