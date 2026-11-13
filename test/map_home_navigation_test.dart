import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/ui/app_theme.dart';
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
          theme: pulsePathTheme(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              padding: const EdgeInsets.only(top: 48, bottom: 34),
              viewPadding: const EdgeInsets.only(top: 48, bottom: 34),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: MapHomeDock(
                    onSize: (_) {},
                    actions: MapHomeActions(
                      onWorkout: () => workout = true,
                      onRoute: () => route = true,
                    ),
                    navigation: MapHomeNavigation(
                      selectedIndex: 0,
                      onSelected: (_) {},
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Начать тренировку'));
      await tester.tap(find.text('Построить маршрут'));
      expect(workout && route, isTrue);
      final actions = tester.getRect(find.byType(MapHomeActions));
      final navigation = tester.getRect(find.byType(MapHomeNavigation));
      expect(actions.bottom, lessThanOrEqualTo(navigation.top - 12));
      expect(navigation.height, 80 + 34);

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
                    onMessages: () {},
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
      if (speed == 62.0) {
        expect(find.text('62'), findsOneWidget);
        final size = tester.getSize(find.byType(Container));
        expect(size.height, lessThan(20));
        expect(size.width, lessThan(50));
      } else {
        expect(find.text('—'), findsNothing);
        expect(find.text(' км/ч'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    }
  });
}
