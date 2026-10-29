import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/models/offline_route_tiles.dart';
import 'package:pulsepath/models/route_step.dart';
import 'package:pulsepath/services/route_places_service.dart';
import 'package:pulsepath/services/voice_guidance_service.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/services/routing_service.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/services/network_recovery_sync.dart';
import 'package:flutter/material.dart' show Icons;

void main() {
  test(
    'Network loss is observable without starting upload retries while offline',
    () async {
      final source = StreamController<bool>();
      final status = <bool>[], retries = <bool>[];
      final sync = NetworkRecoverySync(
        changes: source.stream,
        onSync: retries.add,
        onStatusChanged: status.add,
      );
      sync.start();
      source.add(true);
      await Future<void>.delayed(Duration.zero);
      source.add(false);
      source.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(sync.offline, isTrue);
      expect(status, [true, false]);
      expect(retries, [true]);
      source.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(sync.offline, isFalse);
      expect(retries, [true, true]);
      sync.dispose();
      await source.close();
    },
  );
  test('Online reconnect keeps the old destination and preserves the route on failure', () async {
    SharedPreferences.setMockInitialValues({});
    final routing = _Connector();
    final controller = MapNavigationController(routingService: routing);
    final base = controller.currentLocation;
    final points = [
      base,
      LatLng(base.latitude + .002, base.longitude),
      LatLng(base.latitude + .006, base.longitude),
    ];
    controller.loadSavedRoute(
      SavedRoute(
        title: 'Track',
        distance: '1 км',
        duration: '4 мин',
        surfaceSummary: '',
        finishPoint: points.last,
        routePoints: points,
        activityType: ActivityType.cycling,
      ),
    );
    routing.fail = true;
    await expectLater(controller.reconnectAhead(), throwsStateError);
    expect(controller.routePoints, points);
    expect(controller.isBookmarked, isTrue);
    routing.fail = false;
    await controller.reconnectAhead();
    expect(routing.target, points[1]);
    expect(controller.routePoints.last, points.last);
    expect(controller.isBookmarked, isFalse);
    expect(controller.followsSavedTrack, isTrue);
    controller.dispose();
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Offline envelope includes intermediate bends, unique bounded tiles and all supported zooms', () {
    final plan = OfflineRouteTiles(const [
      LatLng(55, 83),
      LatLng(55.02, 83.03),
      LatLng(55, 83.01),
    ]);
    expect(plan.north, greaterThan(55.02));
    expect(plan.east, greaterThan(83.03));
    final tiles = plan.tiles;
    expect(tiles.toSet().length, tiles.length);
    expect(tiles.map((t) => t.z).toSet(), {13, 14, 15, 16});
    expect(tiles.length, lessThanOrEqualTo(8000));
  });
  test('Oversized, polar, invalid and antimeridian areas are rejected before download', () {
    for (final points in [
      <LatLng>[],
      const [LatLng(0, 0)],
      const [LatLng(0, 179.9), LatLng(0, -179.9)],
      const [LatLng(86, 0), LatLng(86, 1)],
      const [LatLng(0, 0), LatLng(60, 60)],
    ]) {
      expect(() => OfflineRouteTiles(points), throwsFormatException);
    }
  });
  test('POI projection orders by route progress and filters private, invalid, duplicate and non-potable points', () {
    final rows = [
      {
        'type': 'node',
        'id': 1,
        'lat': 0,
        'lon': .008,
        'tags': {'amenity': 'cafe'},
      },
      {
        'type': 'node',
        'id': 2,
        'lat': 0,
        'lon': .002,
        'tags': {'amenity': 'drinking_water'},
      },
      {
        'type': 'node',
        'id': 2,
        'lat': 0,
        'lon': .002,
        'tags': {'amenity': 'drinking_water'},
      },
      {
        'type': 'node',
        'id': 3,
        'lat': 0,
        'lon': .003,
        'tags': {'amenity': 'drinking_water', 'drinking_water': 'no'},
      },
      {
        'type': 'node',
        'id': 4,
        'lat': 999,
        'lon': .004,
        'tags': {'amenity': 'cafe'},
      },
      {
        'type': 'node',
        'id': 5,
        'lat': 0,
        'lon': .004,
        'tags': {'amenity': 'bench', 'access': 'private'},
      },
    ];
    final result = RoutePlacesService.parse(rows, const [
      LatLng(0, 0),
      LatLng(0, .01),
    ]);
    expect(result.map((p) => p.kind), ['Вода', 'Кафе']);
    expect(result.first.alongMeters, inInclusiveRange(220, 225));
    expect(result.first.detourMeters, lessThan(1));
  });
  test(
    'Overpass errors and incomplete responses cannot masquerade as no places',
    () async {
      for (final response in [
        http.Response('bad', 503),
        http.Response(jsonEncode({'remark': 'timeout', 'elements': []}), 200),
      ]) {
        final client = MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.body, contains('around:500'));
          return response;
        });
        await expectLater(
          RoutePlacesService(client: client)
              .fetch(const [LatLng(0, 0), LatLng(0, .001)]),
          throwsStateError,
        );
        client.close();
      }
    },
  );
  test('Brief speech suppresses early call and forwards configured volume to native TTS', () async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final spoken = <Map<dynamic, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('pulsepath/voice_guidance'),
          (call) async {
            if (call.method == 'prepare') return true;
            if (call.method == 'speak') {
              spoken.add(call.arguments as Map);
              return true;
            }
            return null;
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('pulsepath/voice_guidance'),
            null,
          ),
    );
    final voice = VoiceGuidanceService.instance;
    await voice.configure(speechVolume: .4, brief: true, navigation: true);
    final step = RouteStep(
      instruction: 'Направо',
      streetName: '',
      icon: Icons.turn_right,
      location: const LatLng(0, 0),
      distance: 100,
      routeOffsetMeters: 100,
    );
    voice.turn(step, 100, 15);
    await Future<void>.delayed(Duration.zero);
    expect(spoken, isEmpty);
    voice.turn(step, 10, 15);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(spoken.length, 1);
    expect(spoken.single['volume'], .4);
    voice.turn(step, 8, 15);
    await Future<void>.delayed(Duration.zero);
    expect(spoken.length, 1);
  });
}

class _Connector extends RoutingService {
  bool fail = false;
  LatLng? target;
  @override
  Future<RoutingResult> buildRoute({
    required LatLng start,
    required LatLng end,
    required ActivityType activity,
    List<LatLng> via = const [],
  }) async {
    target = end;
    if (fail) throw StateError('offline');
    return RoutingResult(
      points: [start, end],
      steps: [],
      distanceKm: 1,
      durationMin: 4,
    );
  }
}
