import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/models/gps_signal.dart';
import 'package:pulsepath/widgets/gps_signal_indicator.dart';
import 'package:pulsepath/widgets/home_steps_pill.dart';
import 'package:pulsepath/widgets/map_home_actions.dart';
import 'package:pulsepath/widgets/map_home_navigation.dart';
import 'package:pulsepath/widgets/map_credits.dart';
import 'package:pulsepath/widgets/map_ui_overlays.dart';

import 'progressive_map_ui_test.dart' show resize, snapshot;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    final file = File('C:/Windows/Fonts/arial.ttf');
    if (await file.exists()) {
      await (FontLoader(
        'Roboto',
      )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  for (final scale in [1.5, 2.0]) {
    for (final dark in [false, true]) {
      testWidgets('map controls remain legible at 360/$scale/dark=$dark', (
        tester,
      ) async {
        resize(tester, const Size(360, 800));
        final signal = ValueNotifier(
          GpsSignal(accuracy: 28, updatedAt: DateTime.now()),
        );
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(360, 800),
                textScaler: TextScaler.linear(scale),
              ),
              child: RepaintBoundary(
                key: key,
                child: Scaffold(
                  body: Stack(
                    children: [
                      Positioned(
                        top: 16,
                        left: 16,
                        right: 16,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            GpsSignalIndicator(signal: signal, compact: true),
                            MapWeatherPill(
                              weather: null,
                              isLoading: false,
                              onTap: () {},
                            ),
                            const HomeStepsPill(),
                          ],
                        ),
                      ),
                      const Positioned(
                        left: 12,
                        right: 82,
                        bottom: 200,
                        child: Align(
                          alignment: Alignment.bottomRight,
                          child: MapCredits(),
                        ),
                      ),
                      Positioned(
                        right: 12,
                        bottom: 200,
                        child: LockButton(
                          isLocked: false,
                          onLock: () {},
                          onUnlocked: () {},
                        ),
                      ),
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 0,
                        child: MapHomeActions(onWorkout: () {}, onRoute: () {}),
                      ),
                    ],
                  ),
                  bottomNavigationBar: MapHomeNavigation(
                    selectedIndex: 1,
                    onSelected: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Лента'), findsOneWidget);
        for (final text in ['Карта', 'Лента', 'Профиль', 'Меню']) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.text(text),
              matching: find.byType(RichText),
            ),
          );
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: text.length),
          );
          expect(boxes.map((b) => b.top).toSet().length, 1, reason: text);
        }
        final gps = tester.getRect(find.byType(GpsSignalIndicator));
        final steps = tester.getRect(find.byType(HomeStepsPill));
        expect(gps.overlaps(steps), isFalse);
        final label = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.text('Шаги…'),
            matching: find.byType(RichText),
          ),
        );
        expect(label.didExceedMaxLines, isFalse);
        final lock = tester.getRect(find.byType(LockButton));
        expect(lock.width, greaterThanOrEqualTo(48));
        expect(lock.height, greaterThanOrEqualTo(48));
        expect(lock.overlaps(tester.getRect(find.byType(MapCredits))), isFalse);
        await snapshot(tester, key, 'accessibility-$scale-$dark');
        await tester.pumpWidget(const SizedBox());
        signal.dispose();
      });
    }
  }
}
