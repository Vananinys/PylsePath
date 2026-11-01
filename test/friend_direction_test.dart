import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/friend_profile.dart';
import 'package:pulsepath/widgets/friend_direction_layer.dart';
import 'package:pulsepath/services/group_ride_service.dart';

FriendProfile friend(String id, double lat, double lon, {bool stale = false}) =>
    FriendProfile(
      id: id,
      username: 'Друг $id',
      liveLatitude: lat,
      liveLongitude: lon,
      liveUpdatedAt: DateTime.now().subtract(Duration(minutes: stale ? 5 : 0)),
    );

void main() {
  test('Meeting directions include only accepted current ride members', () {
    GroupMember member(String id, {bool point = false}) => GroupMember(
      userId: id,
      username: id,
      distanceMeters: 0,
      durationSeconds: 0,
      updatedAt: DateTime.now(),
      latitude: point ? 1 : null,
      longitude: point ? 1 : null,
    );
    final members = [
      member('me'),
      member('accepted'),
      member('clubmate', point: true),
    ];
    final friends = [
      friend('accepted', 0, 1),
      friend('pending', 1, 0),
      friend('outsider', 2, 0),
    ];
    List<FriendProfile> scope(
      String? room, {
      String? owner = 'me',
      bool recording = false,
      String? workoutRoom,
    }) => rideDirectionFriends(
      room: room,
      userId: owner,
      members: members,
      friends: friends,
      recording: recording,
      workoutRoom: workoutRoom,
    );
    expect(scope(null), isEmpty);
    expect(scope('ride').map((f) => f.id), ['accepted', 'clubmate']);
    expect(scope('ride', owner: 'other-account'), isEmpty);
    expect(scope('ride', recording: true), isEmpty);
    expect(
      scope('ride', recording: true, workoutRoom: 'previous-ride'),
      isEmpty,
    );
    expect(scope('ride', recording: true, workoutRoom: 'ride'), hasLength(2));
    expect(
      rideDirectionFriends(
        room: 'ride',
        userId: 'me',
        members: [member('me')],
        friends: friends,
      ),
      isEmpty,
    );
  });
  test('Directions follow camera rotation and the nearest date-line world', () {
    MapCamera camera(double rotation, {LatLng center = const LatLng(0, 0)}) =>
        MapCamera(
          crs: const Epsg3857(),
          center: center,
          zoom: 10,
          rotation: rotation,
          nonRotatedSize: const math.Point(400, 600),
        );
    final east = friendScreenPosition(camera(0), const LatLng(0, 1));
    expect(east.dx, greaterThan(400));
    expect(east.dy, closeTo(300, .01));
    final rotated = friendScreenPosition(camera(90), const LatLng(0, 1));
    expect(rotated.dx, closeTo(200, .01));
    expect(rotated.dy, greaterThan(600));
    final acrossDateLine = friendScreenPosition(
      camera(0, center: const LatLng(0, 179.9)),
      const LatLng(0, -179.9),
    );
    expect(acrossDateLine.dx, greaterThan(200));
    expect(acrossDateLine.dx, lessThan(400));
  });

  test(
    'Visible friends have no arrow; edge badges fit and point the right way',
    () {
      const view = Rect.fromLTWH(12, 100, 300, 400);
      const badge = Size(120, 56);
      expect(friendEdgePosition(view.center, view, badge), isNull);
      final east = friendEdgePosition(const Offset(1000, 300), view, badge)!;
      expect(east.dx, 252);
      expect(east.dy, 300);
      final northWest = friendEdgePosition(
        const Offset(-1000, -1000),
        view,
        badge,
      )!;
      expect(northWest.dx, lessThan(view.center.dx));
      expect(northWest.dy, lessThan(view.center.dy));
      expect(view.contains(northWest - const Offset(60, 28)), isTrue);
      expect(
        friendEdgePosition(const Offset(double.nan, 1), view, badge),
        isNull,
      );
      expect(
        friendEdgePosition(
          const Offset(1000, 1),
          const Rect.fromLTWH(0, 0, 40, 40),
          badge,
        ),
        isNull,
      );
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'Edge friends, stale age, grouping and taps at 200% $brightness',
      (tester) async {
        tester.view.resetPhysicalSize();
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        FriendProfile? selected;
        final controller = MapController();
        Widget map(List<FriendProfile> friends) => MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: brightness,
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: FlutterMap(
              mapController: controller,
              options: const MapOptions(
                initialCenter: LatLng(0, 0),
                initialZoom: 14,
              ),
              children: [
                FriendDirectionLayer(
                  friends: friends,
                  myPosition: const LatLng(0, 0),
                  onSelect: (friend) => selected = friend,
                ),
              ],
            ),
          ),
        );
        final data = [
          friend('east', 0, 1, stale: true),
          friend('north', 1, 0),
          friend('visible', 0, 0),
          friend('invalid', double.nan, 0),
        ];
        await tester.pumpWidget(map(data));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('friend-direction-visible')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('friend-direction-invalid')),
          findsNothing,
        );
        expect(find.textContaining('Был 5 мин назад'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('friend-direction-east')));
        expect(selected?.id, 'east');
        controller.move(const LatLng(0, 1), 14);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('friend-direction-east')),
          findsNothing,
        );
        controller.move(const LatLng(0, 0), 14);
        await tester.pumpWidget(map([friend('a', 0, 1), friend('b', 0, 1.01)]));
        await tester.pump();
        expect(find.text('Друзья · 2'), findsOneWidget);
        await tester.tap(find.text('Друзья · 2'));
        await tester.pumpAndSettle();
        expect(find.text('Друзья за краем карты'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Друг b'),
          150,
          scrollable: find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.tap(find.text('Друг b'));
        await tester.pumpAndSettle();
        expect(selected?.id, 'b');
        await tester.pumpWidget(map([]));
        await tester.pump();
        expect(find.byIcon(Icons.navigation_rounded), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }
}
