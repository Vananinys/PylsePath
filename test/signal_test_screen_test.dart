import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/screens/signal_test_screen.dart';

void main() {
  testWidgets('Signal diagnostic remains readable with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: SignalTestScreen(
            runDiagnostic: () async => [
              'Подмена сохранённого пакета отклонена',
            ],
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(find.text('Запустить проверку'), 250);
    await tester.tap(find.text('Запустить проверку'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('✓ Подмена сохранённого пакета отклонена'),
      200,
    );
    expect(tester.takeException(), isNull);
  });
}
