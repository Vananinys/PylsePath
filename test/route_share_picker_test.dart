import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/widgets/route_share_sheet.dart';

SavedRoute route(String title, double km, int minutes) => SavedRoute(
  title: title,
  distance: '$km км',
  duration: '$minutes мин',
  distanceMeters: km * 1000,
  durationSeconds: minutes * 60,
  createdAt: DateTime(2026, 11, 10),
  surfaceSummary: '',
  finishPoint: const LatLng(0, 0),
  routePoints: const [],
  activityType: ActivityType.cycling,
);

void main() {
  test('Date bounds include the whole final day and combine with duration', () {
    final item = route('Маршрут', 8, 35);
    expect(
      matchesLocalRouteFilters(
        item,
        dates: DateTimeRange(
          start: DateTime(2026, 11, 10),
          end: DateTime(2026, 11, 10),
        ),
        minMinutes: 30,
        maxDistance: 10,
      ),
      isTrue,
    );
    expect(
      matchesLocalRouteFilters(
        item,
        dates: DateTimeRange(
          start: DateTime(2026, 11, 11),
          end: DateTime(2026, 11, 12),
        ),
      ),
      isFalse,
    );
    expect(matchesLocalRouteFilters(item, maxMinutes: 20), isFalse);
  });
  testWidgets(
    'Categories and distance and duration filters narrow the choice',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocalRoutePicker(
              owner: null,
              routes: [
                route('Длинный маршрут', 30, 90),
                route('Короткий маршрут', 3, 15),
              ],
              workouts: [route('Тренировка', 8, 35)],
            ),
          ),
        ),
      );
      expect(find.text('Длинный маршрут'), findsOneWidget);
      expect(find.text('Тренировка'), findsNothing);
      await tester.tap(find.byTooltip('Фильтры'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Расстояние от, км'),
        '5',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Длительность до, мин'),
        '60',
      );
      await tester.tap(find.text('Применить'));
      await tester.pumpAndSettle();
      expect(find.text('Нет подходящих записей'), findsOneWidget);
      await tester.tap(find.text('Мои тренировки'));
      await tester.pumpAndSettle();
      expect(find.text('Тренировка'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
