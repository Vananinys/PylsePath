import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/recent_stickers.dart';
import 'package:pulsepath/data/trail_appearance.dart';
import 'package:pulsepath/models/live_trail_style.dart';
import 'package:pulsepath/widgets/activity_trail_layer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Recent selections are unique, persisted and isolated per account',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = RecentStickers();
      await Future.wait([
        store.used('🔥', 'a'),
        store.used('👍', 'a'),
        store.used('🔥', 'a'),
      ]);
      expect(await RecentStickers().load('a'), ['🔥', '👍']);
      expect(await store.load('b'), isEmpty);
      expect(
        RecentStickers.order(['🚴', '🔥', '👍'], ['🔥', 'unknown', '👍']),
        ['🔥', '👍', '🚴'],
      );
    },
  );
  test('Every effect round-trips, draws, and unknown versions fall back', () {
    for (final effect in MotionEffect.values) {
      final choice = const LiveTrailStyle().copyWith(effect: effect);
      expect(LiveTrailStyle.fromRow(choice.toRow()).effect, effect);
      final recorder = ui.PictureRecorder();
      final painter = TrailPainter(
        [
          [const Offset(5, 20), const Offset(200, 20)],
        ],
        TrailStyle.footprints,
        Colors.blue,
        12,
        20,
        effect: effect,
      );
      painter.paint(Canvas(recorder), const Size(220, 50));
      recorder.endRecording().dispose();
      expect(
        painter.shouldRepaint(
          TrailPainter([], TrailStyle.footprints, Colors.blue, 12, 20),
        ),
        isTrue,
      );
    }
    expect(
      LiveTrailStyle.fromRow({'version': 1, 'effect': 'unknown'}).effect,
      MotionEffect.none,
    );
    expect(
      LiveTrailStyle.fromRow({'version': 999, 'effect': 'pixel'}).effect,
      MotionEffect.none,
    );
  });
}
