import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pulsepath/widgets/ride_share_card.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required Widget child,
  double width = 360,
  double textScale = 1.0,
}) async {
  // Масштаб текста задаётся переопределением MediaQuery вокруг карточки.
  await tester.pumpWidget(
    _wrap(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: SizedBox(width: width, child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('обычный заезд: бренд, активность и три метрики', (
    tester,
  ) async {
    await _pump(
      tester,
      child: const RideShareCard(
        activityType: 'Велосипед',
        distanceMeters: 15420,
        durationSeconds: 3723,
        elevationGainMeters: 215,
      ),
    );

    expect(find.text('PulsePath'), findsOneWidget);
    expect(find.text('Велосипед'), findsOneWidget);
    expect(find.text('15.42 км'), findsOneWidget);
    expect(find.text('1:02:03'), findsOneWidget);
    expect(find.text('215 м'), findsOneWidget);
    expect(find.text('Дистанция'), findsOneWidget);
    expect(find.text('Длительность'), findsOneWidget);
    expect(find.text('Набор высоты'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('нет переполнения при ширине 320 px, масштабе 1.6 и длинном '
      'названии активности', (tester) async {
    await _pump(
      tester,
      width: 320,
      textScale: 1.6,
      child: const RideShareCard(
        activityType: 'Очень длинное название активности на горном велосипеди '
            'с длинным описанием маршрута',
        distanceMeters: 123456,
        durationSeconds: 12345,
        elevationGainMeters: 987,
      ),
    );

    expect(tester.takeException(), isNull);
    // Название обрезается, но не вылезает за карточку.
    final title = tester.widget<Text>(
      find.text(
        'Очень длинное название активности на горном велосипеди '
        'с длинным описанием маршрута',
      ),
    );
    expect(title.maxLines, 2);
    expect(title.overflow, TextOverflow.ellipsis);
  });

  testWidgets('без набора высоты метрика не показывается', (tester) async {
    await _pump(
      tester,
      child: const RideShareCard(
        activityType: 'Бег',
        distanceMeters: 5000,
        durationSeconds: 1500,
      ),
    );

    expect(find.text('5.00 км'), findsOneWidget);
    expect(find.text('25:00'), findsOneWidget);
    expect(find.text('Набор высоты'), findsNothing);
    expect(find.text('0 м'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('нулевая длительность показывается как 0:00', (tester) async {
    await _pump(
      tester,
      child: const RideShareCard(
        activityType: 'Велосипед',
        distanceMeters: 0,
        durationSeconds: 0,
        elevationGainMeters: 0,
      ),
    );

    expect(find.text('0 м'), findsNWidgets(2));
    expect(find.text('0:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('отрицательные, бесконечные и NaN числа показываются как —', (
    tester,
  ) async {
    await _pump(
      tester,
      child: const RideShareCard(
        activityType: 'Велосипед',
        distanceMeters: -100,
        durationSeconds: double.infinity,
        elevationGainMeters: double.nan,
      ),
    );

    expect(find.text('—'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('короткая дистанция показывается в метрах', (tester) async {
    await _pump(
      tester,
      child: const RideShareCard(
        activityType: 'Прогулка',
        distanceMeters: 950,
        durationSeconds: 61,
      ),
    );

    expect(find.text('950 м'), findsOneWidget);
    expect(find.text('1:01'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
