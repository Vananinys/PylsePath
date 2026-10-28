import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/widgets/ride_share_preview.dart';
import 'package:pulsepath/widgets/ride_share_card.dart';

void main() {
  testWidgets(
    'preview fits a small phone with large text and closes without sharing',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var shares = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => RideSharePreview(
                    activityType:
                        'Очень длинное название велосипедной активности',
                    distanceMeters: 123456,
                    durationSeconds: 12345,
                    onShare: (_, _) async {
                      shares++;
                    },
                  ),
                ),
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      expect(find.byType(RideShareCard), findsOneWidget);
      expect(find.text('Набор высоты'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Закрыть'));
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byType(RideShareCard), findsNothing);
      expect(shares, 0);
    },
  );

  testWidgets('exports a real PNG with only the summary card', (tester) async {
    if (const bool.fromEnvironment('RENDER_RIDE_CARD')) {
      await tester.runAsync(() async {
        final font = FontLoader('PreviewFont')
          ..addFont(
            Future.value(
              ByteData.sublistView(
                await File(r'C:\Windows\Fonts\arial.ttf').readAsBytes(),
              ),
            ),
          );
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  r'C:\src\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
                ).readAsBytes(),
              ),
            ),
          );
        await icons.load();
      });
    }
    Uint8List? exported;
    Rect? shareOrigin;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: const bool.fromEnvironment('RENDER_RIDE_CARD')
              ? 'PreviewFont'
              : null,
        ),
        home: Scaffold(
          body: RideSharePreview(
            activityType: 'Велосипед',
            distanceMeters: 15420,
            durationSeconds: 3723,
            elevationGainMeters: 215,
            onShare: (png, origin) async {
              exported = png;
              shareOrigin = origin;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Поделиться картинкой'));
    for (var frame = 0; frame < 100 && exported == null; frame++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pumpAndSettle();
    expect(exported, isNotNull);
    expect(exported!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(shareOrigin!.width, greaterThan(0));
    expect(shareOrigin!.height, greaterThan(0));
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(exported!);
      try {
        final frame = await codec.getNextFrame();
        expect(frame.image.width, inInclusiveRange(300, 1260));
        expect(frame.image.height, greaterThan(100));
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
      if (const bool.fromEnvironment('RENDER_RIDE_CARD')) {
        await Directory('build/qa').create(recursive: true);
        await File('build/qa/ride-share-card.png').writeAsBytes(exported!);
      }
    });
    expect(find.text('Поделиться картинкой'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
