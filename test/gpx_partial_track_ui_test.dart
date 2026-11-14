// Widget tests for the partial-track warning on the workout detail screen:
// the banner explains why some actions are unavailable, dangerous actions
// confirm or refuse explicitly, and the warning survives a narrow screen
// with a large font.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/workout_record.dart';
import 'package:pulsepath/screens/workout_detail_screen.dart';

SavedRoute _ride({bool partial = false}) => SavedRoute(
  localId: 'probe-ride',
  title: 'Облачный заезд',
  distance: '500.00 км',
  duration: '27 ч',
  surfaceSummary: '',
  finishPoint: const LatLng(56.4801, 84.9501),
  routePoints: const [
    LatLng(56.48, 84.95),
    LatLng(56.4801, 84.9501),
    LatLng(56.4802, 84.9502),
  ],
  activityType: ActivityType.cycling,
  cloudSynced: true,
  remoteId: 'remote-1',
  routePointsPartial: partial,
  routePointsTotal: partial ? 152340 : 0,
  createdAt: DateTime.utc(2026, 11, 15, 9),
);

Future<void> _pump(
  WidgetTester tester, {
  required bool partial,
  double textScale = 1.0,
  Size size = const Size(800, 1200),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: WorkoutDetailScreen(
          workout: WorkoutRecord.fromSavedRoute(_ride(partial: partial)),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The screen is a SingleChildScrollView; buttons below the fold must be
/// scrolled into view before a tap.
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 400));
}

/// The map inside RidePulseView keeps animating, so pumpAndSettle never
/// finishes: settle with fixed pumps instead.
Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  testWidgets('a complete cloud ride shows no partial-track banner', (
    tester,
  ) async {
    await _pump(tester, partial: false);
    expect(find.textContaining('Трек прочитан не полностью'), findsNothing);
  });

  testWidgets(
    'a partial cloud ride shows the banner with truthful numbers and the '
    'unavailable actions',
    (tester) async {
      await _pump(tester, partial: true);
      expect(find.textContaining('Трек прочитан не полностью'), findsOneWidget);
      // Same numbers the parser reported for the file (3 of 152 340).
      expect(find.textContaining('показано 3 из 152340'), findsOneWidget);
      expect(find.textContaining('Создание маршрута'), findsOneWidget);
      // The guarded actions stay visible; the banner explains them.
      expect(find.byTooltip('Экспорт GPX'), findsOneWidget);
      expect(find.byTooltip('Отправить в чат'), findsOneWidget);
    },
  );

  testWidgets(
    'creating a route from a partial track is refused with an explanation',
    (tester) async {
      await _pump(tester, partial: true);
      await _tapVisible(tester, find.text('Создать маршрут из этого трека'));
      expect(
        find.textContaining('Маршрут нельзя создать из частично прочитанного'),
        findsOneWidget,
      );
      // The route editor never opened: the detail screen is still on top.
      expect(find.byType(WorkoutDetailScreen), findsOneWidget);
    },
  );

  testWidgets(
    'GPX export of a partial track asks for confirmation first',
    (tester) async {
      await _pump(tester, partial: true);
      await tester.tap(find.byTooltip('Экспорт GPX'));
      await _settle(tester);
      expect(find.text('Трек неполный'), findsOneWidget);
      expect(find.textContaining('Экспорт GPX будет содержать'), findsOneWidget);
      // Cancel keeps the share sheet closed.
      await tester.tap(find.text('Отмена'));
      await _settle(tester);
      expect(find.text('Трек неполный'), findsNothing);
    },
  );

  testWidgets(
    'the warning stays readable on a narrow screen with a large font',
    (tester) async {
      await _pump(
        tester,
        partial: true,
        textScale: 2.0,
        size: const Size(320, 640),
      );
      expect(find.textContaining('Трек прочитан не полностью'), findsOneWidget);
      // Any layout exception must not come from the banner itself: the only
      // known pre-existing overflow at this scale lives in ride_pulse_view.
      final exceptions = <String>[];
      Object? exception = tester.takeException();
      while (exception != null) {
        exceptions.add(exception.toString());
        exception = tester.takeException();
      }
      expect(
        exceptions.where(
          (e) => e.contains('workout_detail_screen.dart'),
        ),
        isEmpty,
        reason: 'the partial-track banner must not overflow',
      );
    },
  );

  testWidgets(
    'a complete ride opens the route editor without a refusal',
    (tester) async {
      await _pump(tester, partial: false);
      await _tapVisible(tester, find.text('Создать маршрут из этого трека'));
      await _settle(tester);
      expect(
        find.textContaining('Маршрут нельзя создать из частично прочитанного'),
        findsNothing,
      );
      // The editor pushed on top; the detail screen is no longer visible.
      expect(find.byType(WorkoutDetailScreen), findsNothing);
    },
  );
}
