import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/trail_appearance.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/screens/trail_appearance_screen.dart';
import 'package:pulsepath/widgets/activity_trail_layer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('all existing activities have a concrete automatic style including scooter override', () {
    final prefs = TrailAppearance();
    for (final activity in ActivityType.values) {
      expect(prefs.effective(activity), isNot(TrailStyle.automatic));
    }
    expect(prefs.effective(ActivityType.driving), TrailStyle.car);
    expect(
      prefs.effective(ActivityType.cycling, transport: 'Самокат'),
      TrailStyle.scooter,
    );
    expect(
      prefs.effective(ActivityType.hiking, transport: 'Самокат'),
      TrailStyle.footprints,
    );
    expect(prefs.effective(ActivityType.nordicWalking), TrailStyle.nordic);
  });
  test('stamp placement resets at GPS gaps and never bridges them', () {
    final stamps = sampleTrail(
      [
        [const Offset(0, 0), const Offset(20, 0)],
        [const Offset(100, 0), const Offset(120, 0)],
      ],
      10,
      const Rect.fromLTWH(-1, -1, 130, 3),
    );
    expect(stamps.map((s) => s.position.dx), [5, 15, 105, 115]);
    expect(stamps[0].alternate, stamps[2].alternate);
  });
  test('a huge clipped edge produces only visible bounded stamps', () {
    final stamps = sampleTrail(
      [
        [const Offset(-1e9, 0), const Offset(1e9, 0)],
      ],
      20,
      const Rect.fromLTRB(-100, -10, 100, 10),
    );
    expect(stamps, isNotEmpty);
    expect(stamps.length, lessThanOrEqualTo(12));
    expect(
      stamps.every((s) => s.position.dx >= -100 && s.position.dx <= 100),
      true,
    );
    expect(
      sampleTrail(
        [
          [Offset.zero, const Offset(100000, 0)],
        ],
        1,
        const Rect.fromLTWH(0, 0, 100000, 100),
        limit: 3,
      ),
      hasLength(3),
    );
    expect(
      sampleTrail(
        [
          [Offset.zero, const Offset(double.nan, 0)],
        ],
        20,
        const Rect.fromLTWH(0, 0, 100, 100),
      ),
      isEmpty,
    );
  });
  test(
    'appearance persists independently from route and navigation data',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('workout_history_guest', 'original-history');
      final model = TrailAppearance();
      await model.update(
        pattern: TrailStyle.car,
        color: 8,
        markerSize: 18,
        density: 40,
        alpha: .5,
        showGuide: false,
        routes: false,
      );
      final restored = TrailAppearance();
      await restored.load();
      expect(restored.style, TrailStyle.car);
      expect(restored.size, 18);
      expect(restored.spacing, 40);
      expect(restored.opacity, .5);
      expect(restored.guide, false);
      expect(restored.onRoutes, false);
      expect(prefs.getString('workout_history_guest'), 'original-history');
    },
  );
  test('future preference format is preserved and invalid scalar fields use safe defaults', () async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode({
      'version': 2,
      'future_style': {'x': 99},
    });
    await prefs.setString(TrailAppearance.key, raw);
    final future = TrailAppearance();
    await future.load();
    await expectLater(
      future.update(pattern: TrailStyle.boots),
      throwsStateError,
    );
    expect(prefs.getString(TrailAppearance.key), raw);
    await prefs.setString(
      TrailAppearance.key,
      jsonEncode({
        'version': 1,
        'size': -10,
        'spacing': 999,
        'color': 'broken',
        'guide': 123,
      }),
    );
    final normal = TrailAppearance();
    await normal.load();
    expect(normal.size, 6);
    expect(normal.spacing, 64);
    expect(normal.colorIndex, 0);
    expect(normal.guide, true);
  });
  test('an update before load cannot replace future settings and wrong types cannot crash load', () async {
    final prefs = await SharedPreferences.getInstance();
    const future = '{"version":99,"future":42}';
    await prefs.setString(TrailAppearance.key, future);
    await expectLater(
      TrailAppearance().update(pattern: TrailStyle.car),
      throwsStateError,
    );
    expect(prefs.getString(TrailAppearance.key), future);
    await prefs.setInt(TrailAppearance.key, 7);
    final wrong = TrailAppearance();
    await wrong.load();
    await expectLater(wrong.update(pattern: TrailStyle.car), throwsStateError);
    expect(prefs.get(TrailAppearance.key), 7);
  });
  testWidgets('appearance controls fit a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = TrailAppearance();
    await tester.pumpWidget(
      MaterialApp(
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: TrailAppearanceScreen(appearance: model),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    Future<void> reveal(String text) async {
      for (
        var i = 0;
        i < 30 && find.text(text).hitTestable().evaluate().isEmpty;
        i++
      ) {
        await tester.drag(find.byType(ListView), const Offset(0, -180));
        await tester.pumpAndSettle();
      }
      expect(find.text(text).hitTestable(), findsOneWidget);
    }

    await reveal('Шаги и палки');
    await tester.tap(find.text('Шаги и палки'));
    await tester.pumpAndSettle();
    expect(model.style, TrailStyle.nordic);
    expect(tester.takeException(), isNull);
    await reveal('Стандартное оформление');
    await tester.tap(find.text('Стандартное оформление'));
    await tester.pumpAndSettle();
    expect(model.style, TrailStyle.automatic);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'panning reuses projected geometry and rotation stays inside map transform',
    (tester) async {
      final controller = MapController();
      const segments = [
        [LatLng(55, 83), LatLng(55.001, 83.001)],
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 320,
            height: 400,
            child: FlutterMap(
              mapController: controller,
              options: const MapOptions(
                initialCenter: LatLng(55, 83),
                initialZoom: 16,
              ),
              children: const [
                ActivityTrailLayer(
                  segments: segments,
                  activity: ActivityType.hiking,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      TrailPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<TrailPainter>()
          .single;
      final before = painter();
      controller.move(const LatLng(55.0003, 83.0003), 16);
      controller.rotate(45);
      await tester.pumpAndSettle();
      final after = painter();
      expect(identical(before.segments, after.segments), true);
      expect(after.origin, isNot(before.origin));
      controller.move(const LatLng(55.0003, 83.0003), 17);
      await tester.pumpAndSettle();
      final zoomed = painter();
      expect(identical(before.segments, zoomed.segments), true);
      expect(zoomed.scale, 2);
      expect(zoomed.spacing, before.spacing);
      expect(segments.first.first, const LatLng(55, 83));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('all trail styles render on a readable contact sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (const bool.fromEnvironment('CAPTURE_TRAILS')) {
      await tester.runAsync(() async {
        final bytes = await File('C:/Windows/Fonts/arial.ttf').readAsBytes();
        final loader = FontLoader('TrailTestFont')
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      });
    }
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: const bool.fromEnvironment('CAPTURE_TRAILS')
              ? 'TrailTestFont'
              : null,
        ),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(
            body: GridView.count(
              crossAxisCount: 2,
              childAspectRatio: 2.3,
              padding: const EdgeInsets.all(20),
              children: [
                for (final style in TrailStyle.values)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Text(style.label),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (ctx, box) => CustomPaint(
                                size: Size.infinite,
                                painter: TrailPainter(
                                  [
                                    [
                                      Offset(5, box.maxHeight * .7),
                                      Offset(
                                        box.maxWidth * .45,
                                        box.maxHeight * .25,
                                      ),
                                      Offset(
                                        box.maxWidth - 5,
                                        box.maxHeight * .65,
                                      ),
                                    ],
                                  ],
                                  style,
                                  Colors.blue,
                                  16,
                                  27,
                                ),
                              ),
                            ),
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
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_TRAILS')) {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('audit/2026-10-28/trails-upgrade/trail-gallery.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
