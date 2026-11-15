import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/screens/signal_registry_screen.dart';

void main() {
  testWidgets('enrollment readable at large text and duplicate taps disabled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: SignalRegistryScreen(
            connect: () {
              calls++;
              return pending.future;
            },
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(find.text('Подключить этот телефон'), 200);
    await tester.tap(find.text('Подключить этот телефон'));
    await tester.pump();
    expect(calls, 1);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    pending.complete();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('Устройство зарегистрировано'),
      200,
    );
    expect(find.textContaining('Устройство зарегистрировано'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
