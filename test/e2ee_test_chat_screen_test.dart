import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:pulsepath/screens/e2ee_test_chat_screen.dart';

void main() {
  testWidgets(
    'local test chat checks protection and decrypts a typed message',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.runAsync(() async {
        await SodiumInit.init();
      });
      tester.view.physicalSize = const Size(320, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const E2eeTestChatScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Локальный тестовый чат'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('✓ Неверный ключ восстановления отклонён'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text('✓ Неверный ключ восстановления отклонён'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byType(TextField),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField), 'Тестовая доставка');
      await tester.ensureVisible(find.text('Зашифровать и прочитать'));
      await tester.tap(find.text('Зашифровать и прочитать'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Алиса: Тестовая доставка'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Алиса: Тестовая доставка'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
