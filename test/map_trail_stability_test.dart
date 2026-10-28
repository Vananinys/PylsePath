import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/trail_appearance.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/friend_profile.dart';
import 'package:pulsepath/models/friend_trail_buffer.dart';
import 'package:pulsepath/widgets/activity_trail_layer.dart';
import 'package:pulsepath/widgets/map_ui_overlays.dart';

void main() {
  testWidgets('Disabled live tail draws neither stamps nor fallback line', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await TrailAppearance.instance.update(friends: false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FlutterMap(
            options: const MapOptions(
              initialCenter: LatLng(0, 0),
              initialZoom: 16,
            ),
            children: const [
              ActivityTrailLayer(
                segments: [
                  [LatLng(0, 0), LatLng(0, .001)],
                ],
                activity: ActivityType.hiking,
                live: true,
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(ActivityTrailLayer),
        matching: find.byType(PolylineLayer),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await TrailAppearance.instance.update(friends: true);
  });
  test('Removing the tail preserves world positions and left/right phase', () {
    final before = sampleTrail(
      [
        [const Offset(0, 0), const Offset(200, 0)],
      ],
      24,
      const Rect.fromLTWH(60, -10, 140, 20),
    );
    final after = sampleTrail(
      [
        [const Offset(60, 0), const Offset(200, 0)],
      ],
      24,
      const Rect.fromLTWH(60, -10, 140, 20),
      phaseOffset: 60,
    );
    expect(
      after.map((s) => s.position).toList(),
      before.map((s) => s.position).toList(),
    );
    expect(
      after.map((s) => s.alternate).toList(),
      before.map((s) => s.alternate).toList(),
    );
  });

  test('Live tail keeps phase as its bounded history slides', () {
    final buffer = FriendTrailBuffer();
    final start = DateTime.utc(2026, 10, 28);
    for (var i = 0; i < 45; i++) {
      final now = start.add(Duration(seconds: i * 2));
      buffer.sync([
        FriendProfile(
          id: 'a',
          username: 'A',
          liveActivity: 'hiking',
          liveLatitude: 0,
          liveLongitude: i * .00005,
          liveUpdatedAt: now,
        ),
      ], now);
    }
    final points = buffer.pointsFor('a');
    expect(points.length, lessThanOrEqualTo(FriendTrailBuffer.maxPoints));
    expect(points.first.pathOffset, greaterThan(0));
    expect(points.last.pathOffset, greaterThan(points.first.pathOffset));
    expect(points.last.position, LatLng(0, 44 * .00005));
    buffer.prune(start.add(const Duration(minutes: 4)));
    expect(buffer.pointsFor('a'), isEmpty);
  });

  test(
    'Friend and idle choices persist independently of recording style',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = TrailAppearance();
      await prefs.update(
        pattern: TrailStyle.boots,
        friendsPattern: TrailStyle.dots,
        idlePattern: TrailStyle.arrows,
        friends: false,
        idle: true,
      );
      final restored = TrailAppearance();
      await restored.load();
      expect(restored.style, TrailStyle.boots);
      expect(restored.friendStyle, TrailStyle.dots);
      expect(restored.idleStyle, TrailStyle.arrows);
      expect(restored.onFriends, isFalse);
      expect(restored.onIdle, isTrue);
      expect(
        restored.effective(ActivityType.running, pattern: restored.friendStyle),
        TrailStyle.dots,
      );
      restored.dispose();
      prefs.dispose();
    },
  );

  testWidgets('Weather pill fits a narrow row at large text size', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 95,
                child: MapWeatherPill(
                  weather: null,
                  isLoading: false,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
