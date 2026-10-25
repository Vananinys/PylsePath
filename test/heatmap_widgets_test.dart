import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/gps_signal.dart';
import 'package:pulsepath/screens/heatmap_explorer_screen.dart';
import 'package:pulsepath/services/developer_scenarios.dart';
import 'package:pulsepath/widgets/gps_signal_indicator.dart';
import 'package:pulsepath/widgets/heatmap_path_layer.dart';

class EmptyTiles extends TileProvider {
  EmptyTiles(this.image);
  final MemoryImage image;
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      image;
}

void main() {
  setUpAll(() async {
    Directory? fonts;
    var parent = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 10; i++) {
      final candidate = Directory(
        '${parent.path}/bin/cache/artifacts/material_fonts',
      );
      if (candidate.existsSync()) {
        fonts = candidate;
        break;
      }
      if (parent.parent.path == parent.path) break;
      parent = parent.parent;
    }
    // Functional checks also run on SDKs without bundled preview fonts.
    if (fonts == null) return;
    for (final font in [
      ('Roboto', 'roboto-regular.ttf'),
      ('MaterialIcons', 'materialicons-regular.otf'),
    ]) {
      final loader = FontLoader(font.$1)
        ..addFont(
          File('${fonts.path}/${font.$2}')
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkoutHistoryRepository.resetInstancesForTesting();
  });
  testWidgets(
    'GPS indicator retries on tap and blocks repeated taps while busy',
    (tester) async {
      var taps = 0;
      final signal = ValueNotifier(const GpsSignal(unavailable: true));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 150,
              child: GpsSignalIndicator(signal: signal, onTap: () => taps++),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(GpsSignalIndicator));
      expect(taps, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 150,
              child: GpsSignalIndicator(
                signal: signal,
                onTap: () => taps++,
                refreshing: true,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(GpsSignalIndicator));
      expect(taps, 1);
      expect(find.text('GPS: обновление…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      signal.dispose();
    },
  );
  testWidgets(
    'heatmap preview renders, filters sport, fits phone, and leaves history empty',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundaryKey = GlobalKey();
      late MemoryImage tile;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(const Color(0xFF151821), BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(1, 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        tile = MemoryImage(data!.buffer.asUint8List());
        image.dispose();
        picture.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: RepaintBoundary(
            key: boundaryKey,
            child: RideHeatmapScreen(
              previewRides: DeveloperScenarios.heatmap(),
              tileProvider: EmptyTiles(tile),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HeatmapPathLayer), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('build/heatmap_preview_test.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.byTooltip('Фильтры и оформление'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Бег'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final layer = tester.widget<HeatmapPathLayer>(
        find.byType(HeatmapPathLayer),
      );
      expect(layer.rides!.where(layer.filter.matches).length, 5);
      await tester.pumpWidget(const SizedBox());
      final history = WorkoutHistoryRepository();
      await history.load();
      expect(history.workoutHistory, isEmpty);
    },
  );
}
