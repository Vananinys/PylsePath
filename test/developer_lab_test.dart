import 'package:flutter/material.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/screens/developer_lab_screen.dart';
import 'package:pulsepath/widgets/settings_hub.dart';

void main() {
  testWidgets('Lab fits a phone and can export its visual preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (const bool.fromEnvironment('CAPTURE_LAB')) {
      await tester.runAsync(() async {
        final loader = FontLoader('LabTest')
          ..addFont(
            File('C:/Windows/Fonts/arial.ttf')
                .readAsBytes()
                .then((b) => ByteData.sublistView(b)),
          );
        await loader.load();
      });
    }
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: const bool.fromEnvironment('CAPTURE_LAB')
              ? 'LabTest'
              : null,
        ),
        home: RepaintBoundary(
          key: key,
          child: DeveloperLabScreen(authorize: () async => true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Начать симуляцию'));
    await tester.tap(find.text('Начать симуляцию'));
    await tester.pump(const Duration(seconds: 35));
    await tester.tap(find.text('Пауза'));
    await tester.drag(find.byType(ListView), const Offset(0, 1200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_LAB')) {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final picture = await boundary.toImage(pixelRatio: 1);
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        final file = File('audit/2026-10-30/developer-beta/lab-preview.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
    }
  });
  testWidgets('Denied access never exposes simulator', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: DeveloperLabScreen(authorize: () async => false)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Начать симуляцию'), findsNothing);
    expect(
      find.text('Требуется подтверждённый доступ владельца'),
      findsOneWidget,
    );
  });
  testWidgets('Lab models GPS loss and stops its timer when closed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: DeveloperLabScreen(authorize: () async => true)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Начать симуляцию'));
    await tester.tap(find.text('Начать симуляцию'));
    await tester.pump(const Duration(seconds: 1));
    await tester.ensureVisible(find.text('GPS доступен'));
    await tester.tap(find.text('GPS доступен'));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, 1200));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('GPS потерян · положение удерживается'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });
  testWidgets('Hidden lab entry requires seven taps and callback', (
    tester,
  ) async {
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsHub(
          children: const [SettingsSectionHeading('Внешний вид'), Text('Demo')],
          summaries: const {'Внешний вид': 'Цвет и карта'},
          onDeveloper: () => opens++,
        ),
      ),
    );
    expect(find.text('Для разработчика'), findsNothing);
    for (var i = 0; i < 7; i++) {
      await tester.tap(find.text('Настройки'));
      await tester.pump();
    }
    await tester.tap(find.text('Для разработчика'));
    expect(opens, 1);
  });
}
