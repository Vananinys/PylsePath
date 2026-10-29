import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/widgets/route_offline_readiness.dart';

void main() {
  testWidgets(
    'Unsaved geometry offers save without claiming offline map coverage',
    (tester) async {
      var saved = 0, maps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RouteOfflineReadiness(
                saved: false,
                hasGeometry: true,
                hasInstructions: true,
                onSave: () => saved++,
                onOpenMaps: () => maps++,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Сохранить маршрут'));
      expect(saved, 1);
      await tester.tap(find.text('Офлайн-карты'));
      expect(maps, 1);
      expect(find.textContaining('покрытие не проверено'), findsOneWidget);
      expect(
        find.textContaining('Пересчёт по дорогам требует интернета'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'Saved route is not confused with downloaded tiles at large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: RouteOfflineReadiness(
                  saved: true,
                  hasGeometry: true,
                  hasInstructions: false,
                  onSave: () {},
                  onOpenMaps: () {},
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Сохранить маршрут'), findsNothing);
      expect(
        find.textContaining('Маршрут сохранён на устройстве'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Поворотные инструкции не подтверждены'),
        findsOneWidget,
      );
      expect(find.textContaining('покрытие не проверено'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
