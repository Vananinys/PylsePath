import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/friend_motion.dart';
import 'package:pulsepath/models/friend_profile.dart';
import 'package:pulsepath/models/friend_trail_buffer.dart';
import 'package:pulsepath/models/live_trail_style.dart';
import 'package:pulsepath/widgets/friend_motion_layer.dart';

void main() {
  testWidgets('Map integration draws direction and cleans up removed friends', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final now = DateTime.now();
    Widget map(double longitude, int seconds, {bool visible = true}) =>
        MaterialApp(
          home: Scaffold(
            body: FlutterMap(
              options: const MapOptions(
                initialCenter: LatLng(0, 0),
                initialZoom: 16,
              ),
              children: [
                FriendMotionLayer(
                  friends: visible
                      ? [
                          FriendProfile(
                            id: 'a',
                            username: 'A',
                            liveLatitude: 0,
                            liveLongitude: longitude,
                            liveActivity: 'idle',
                            liveUpdatedAt: now.subtract(
                              Duration(seconds: seconds),
                            ),
                          ),
                        ]
                      : [],
                  markerBuilder: (_) => const Text('Avatar'),
                  onSelect: (_) {},
                ),
              ],
            ),
          ),
        );
    await tester.pumpWidget(map(0, 10));
    expect(find.byIcon(Icons.navigation_rounded), findsNothing);
    await tester.pumpWidget(map(.0001, 5));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.navigation_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(map(.0001, 5, visible: false));
    expect(find.text('Avatar'), findsNothing);
    expect(find.byIcon(Icons.navigation_rounded), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
  final start = DateTime.utc(2026, 10, 30);
  test('Interpolates, retargets without snapping, and never extrapolates', () {
    final motion = FriendMotion(const LatLng(0, 0), start);
    final tick = start.add(const Duration(seconds: 5));
    motion.update(const LatLng(0, .0001), tick, tick);
    final halfway = tick.add(const Duration(milliseconds: 900));
    expect(motion.position(halfway).longitude, closeTo(.00005, 1e-10));
    final before = motion.position(halfway);
    motion.update(
      const LatLng(0, .0002),
      tick.add(const Duration(seconds: 1)),
      halfway,
    );
    expect(
      motion.position(halfway).longitude,
      closeTo(before.longitude, 1e-10),
    );
    expect(
      motion.position(tick.add(const Duration(minutes: 1))).longitude,
      closeTo(.0002, 1e-10),
    );
    // Delayed/out-of-order events cannot move the target backwards.
    motion.update(const LatLng(0, -.001), start, halfway);
    expect(motion.target.longitude, .0002);
  });

  test(
    'Heading is geographic, expires at rest, and jumps are not animated',
    () {
      final motion = FriendMotion(const LatLng(0, 0), start);
      final tick = start.add(const Duration(seconds: 5));
      motion.update(const LatLng(0, .0001), tick, tick);
      expect(motion.direction(tick), closeTo(90, .01));
      expect(motion.direction(tick.add(const Duration(seconds: 16))), isNull);
      final jump = tick.add(const Duration(seconds: 1));
      motion.update(const LatLng(1, 1), jump, jump);
      expect(motion.position(jump), const LatLng(1, 1));
      expect(motion.direction(jump), isNull);
      expect(motion.animating(jump), isFalse);
    },
  );

  FriendProfile friend(
    int seconds,
    double longitude, {
    String activity = 'idle',
    bool enabled = true,
  }) => FriendProfile(
    id: 'friend',
    username: 'Friend',
    liveLatitude: 0,
    liveLongitude: longitude,
    liveUpdatedAt: start.add(Duration(seconds: seconds)),
    liveActivity: activity,
    liveTrailStyle: LiveTrailStyle(enabled: enabled),
  );

  test(
    'Idle movement, 40s delivery gap and activity change retain the tail',
    () {
      final buffer = FriendTrailBuffer();
      buffer.sync([friend(0, 0)], start);
      buffer.sync([friend(5, .0001)], start.add(const Duration(seconds: 5)));
      buffer.prune(start.add(const Duration(seconds: 40)));
      expect(buffer.pointsFor('friend'), hasLength(2));
      buffer.sync([
        friend(45, .0002, activity: 'cycling'),
      ], start.add(const Duration(seconds: 45)));
      expect(buffer.pointsFor('friend'), hasLength(3));
      expect(buffer.pointsFor('friend').first.position, const LatLng(0, 0));
      buffer.prune(start.add(const Duration(minutes: 3)));
      expect(buffer.pointsFor('friend'), isEmpty);
    },
  );

  test(
    'Owner disable clears tail; re-enable cannot reveal hidden movement',
    () {
      final buffer = FriendTrailBuffer();
      buffer.sync([friend(0, 0)], start);
      buffer.sync([friend(5, .0001)], start.add(const Duration(seconds: 5)));
      buffer.sync([
        friend(10, .0002, enabled: false),
      ], start.add(const Duration(seconds: 10)));
      expect(buffer.pointsFor('friend'), isEmpty);
      buffer.sync([friend(15, .0003)], start.add(const Duration(seconds: 15)));
      expect(buffer.pointsFor('friend'), hasLength(1));
      buffer.sync([], start.add(const Duration(seconds: 16)));
      expect(buffer.pointsFor('friend'), isEmpty);
    },
  );
}
