import 'package:flutter/material.dart';

import 'dart:io';
import 'dart:typed_data' as binary;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/models/bike_setup.dart';
import 'package:pulsepath/models/bike_equipment.dart';
import 'package:pulsepath/widgets/bike_workshop_scene.dart';

void main() {
  testWidgets('workshop visual preview', (tester) async {
    const preview = bool.fromEnvironment('GARAGE_PREVIEW');
    if (preview) {
      final textFont = FontLoader('PreviewSans')
        ..addFont(
          Future.value(
            binary.ByteData.sublistView(
              File('C:/Windows/Fonts/segoeui.ttf').readAsBytesSync(),
            ),
          ),
        );
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            binary.ByteData.sublistView(
              File(
                'C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytesSync(),
            ),
          ),
        );
      await textFont.load();
      await icons.load();
    }
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorSchemeSeed: Colors.deepOrange,
          useMaterial3: true,
          fontFamily: 'PreviewSans',
        ),
        home: Scaffold(
          appBar: AppBar(title: const Text('Мой велосипед')),
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: BikeWorkshopScene(
                parts: const [
                  BikePart(
                    id: 'chain',
                    name: 'Цепь',
                    intervalKm: 300,
                    lastServiceKm: 800,
                  ),
                  BikePart(
                    id: 'fork',
                    name: 'Вилка',
                    intervalHours: 50,
                    lastServiceHours: 0,
                  ),
                ],
                odometer: 1000,
                totalHours: 55,
                setup: const BikeSetup(diagram: 'enduro'),
                selectedId: 'chain',
                onSelect: (_) {},
                onOpen: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (preview) {
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('../build/previews/garage-1.9.1.png'),
      );
    }
  });
}
