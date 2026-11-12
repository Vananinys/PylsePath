import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/friend_profile.dart';
import 'package:pulsepath/services/smooth_map_position.dart';
import 'package:pulsepath/widgets/friend_markers_layer.dart';

void main() {
  test('Position interpolation takes the short path across the date line', () {
    final midpoint = SmoothMapPosition.interpolate(
      const LatLng(0, 179),
      const LatLng(2, -179),
      .5,
    );
    expect(midpoint.latitude, 1);
    expect(midpoint.longitude.abs(), 180);
  });

  test(
    'First position and large relocations snap without crossing the map',
    () {
      final position = SmoothMapPosition(const LatLng(0, 0));
      position.update(const LatLng(55, 83));
      expect(position.value, const LatLng(55, 83));
      position.update(const LatLng(56, 84));
      expect(position.value, const LatLng(56, 84));
      position.dispose();
    },
  );

  testWidgets('Overlapping friends group and allow selecting each member', (
    tester,
  ) async {
    FriendProfile? selected;
    final friends = [
      for (var i = 0; i < 2; i++)
        FriendProfile(
          id: '$i',
          username: 'Друг $i',
          liveLatitude: 55,
          liveLongitude: 83,
          liveUpdatedAt: DateTime.now(),
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FlutterMap(
            options: const MapOptions(
              initialCenter: LatLng(55, 83),
              initialZoom: 15,
            ),
            children: [
              FriendMarkersLayer(
                friends: friends,
                markerBuilder: (friend) => const Icon(Icons.person),
                onSelect: (friend) => selected = friend,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('2'), findsOneWidget);
    expect(find.byIcon(Icons.person), findsNothing);
    await tester.tap(find.text('2'));
    await tester.pumpAndSettle();
    expect(find.text('Друзей рядом: 2'), findsOneWidget);
    await tester.tap(find.text('Друг 1'));
    await tester.pumpAndSettle();
    expect(selected?.id, '1');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Avatar stays on its coordinate and clusters follow zoom and rotation',
    (tester) async {
      final controller = MapController();
      final friends = [
        FriendProfile(
          id: '0',
          username: 'A',
          liveLatitude: 55,
          liveLongitude: 83,
          liveUpdatedAt: DateTime.now(),
        ),
        FriendProfile(
          id: '1',
          username: 'B',
          liveLatitude: 55,
          liveLongitude: 83.01,
          liveUpdatedAt: DateTime.now(),
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FlutterMap(
              mapController: controller,
              options: const MapOptions(
                initialCenter: LatLng(55, 83),
                initialZoom: 16,
              ),
              children: [
                FriendMarkersLayer(
                  friends: friends,
                  markerBuilder: (friend) => SizedBox(
                    width: 118,
                    height: 100,
                    child: Stack(
                      children: [
                        Positioned(
                          top: 0,
                          left: 42.5,
                          child: SizedBox(
                            key: ValueKey(friend.id),
                            width: 33,
                            height: 33,
                          ),
                        ),
                      ],
                    ),
                  ),
                  onSelect: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      final center = tester.getCenter(find.byKey(const ValueKey('0')));
      expect(center.dx, closeTo(400, 1));
      expect(center.dy, closeTo(300, 1));
      controller.rotate(60);
      await tester.pumpAndSettle();
      final rotated = tester.getCenter(find.byKey(const ValueKey('0')));
      expect(rotated.dx, closeTo(center.dx, 1));
      expect(rotated.dy, closeTo(center.dy, 1));
      controller.move(const LatLng(55, 83), 10);
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      controller.move(const LatLng(55, 83), 16);
      await tester.pumpAndSettle();
      expect(find.text('2'), findsNothing);
      expect(find.byKey(const ValueKey('0')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
