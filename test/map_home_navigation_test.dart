import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/widgets/map_home_navigation.dart';
import 'package:pulsepath/widgets/map_home_actions.dart';
import 'package:pulsepath/widgets/map_speed_badge.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('map actions and navigation at 320px and 200% $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var workout = false, route = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                MapHomeActions(
                  onWorkout: () => workout = true,
                  onRoute: () => route = true,
                ),
                MapHomeNavigation(selectedIndex: 0, onSelected: (_) {}),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Начать тренировку'));
      await tester.tap(find.text('Построить маршрут'));
      expect(workout && route, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('sections switch and return to the mounted map', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => MapHomeSections(
                    initialIndex: 1,
                    community: const Text('Community content'),
                    profile: const Text('Profile content'),
                    onMenu: () {},
                  ),
                ),
              ),
              child: const Text('Map content'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Map content'));
    await tester.pumpAndSettle();
    expect(find.text('Community content'), findsOneWidget);
    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Profile content'), findsOneWidget);
    await tester.tap(find.text('Карта'));
    await tester.pumpAndSettle();
    expect(find.text('Map content'), findsOneWidget);
  });

  testWidgets('missing and invalid speeds never become a false zero', (
    tester,
  ) async {
    for (final speed in [null, double.nan, -1.0, 62.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(child: MapSpeedBadge(speed: speed)),
        ),
      );
      expect(find.text(speed == 62.0 ? '62' : '—'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
