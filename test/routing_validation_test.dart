import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/services/routing_service.dart';

class PendingRouting extends RoutingService {
  final result = Completer<RoutingResult>();
  @override
  Future<RoutingResult> buildRoute({
    required LatLng start,
    required LatLng end,
    required ActivityType activity,
    List<LatLng> via = const [],
  }) => result.future;
}

void main() {
  const start = LatLng(52.54, 85.2), end = LatLng(52.541, 85.201);
  Map<String, dynamic> route() => {
    'code': 'Ok',
    'routes': [
      {
        'distance': 1200,
        'duration': 360,
        'geometry': {
          'coordinates': [
            [85.2, 52.54],
            [85.201, 52.541],
          ],
        },
        'legs': [],
      },
    ],
  };
  Future<RoutingResult> request(Object data, {int status = 200}) =>
      RoutingService(
        client: MockClient(
          (r) async =>
              http.Response(data is String ? data : jsonEncode(data), status),
        ),
      ).buildRoute(start: start, end: end, activity: ActivityType.hiking);
  test('invalid coordinates and too many stops fail before HTTP', () {
    final service = RoutingService(
      client: MockClient((_) async => throw StateError('Must not request')),
    );
    expect(
      () => service.buildRoute(
        start: LatLng(double.nan, 0),
        end: end,
        activity: ActivityType.hiking,
      ),
      throwsA(isA<RoutingException>()),
    );
    expect(
      () => service.buildRoute(
        start: start,
        end: end,
        via: List.filled(9, end),
        activity: ActivityType.cycling,
      ),
      throwsA(isA<RoutingException>()),
    );
  });
  test(
    'foot routing uses its own graph and bounds all snap radiuses',
    () async {
      final client = MockClient((r) async {
        expect(r.url.path, startsWith('/routed-foot/'));
        expect(r.url.queryParameters['radiuses'], '200;200');
        return http.Response(jsonEncode(route()), 200);
      });
      final result = await RoutingService(client: client)
          .buildRoute(start: start, end: end, activity: ActivityType.hiking);
      expect(result.durationMin, 18);
    },
  );
  test(
    'car ETA uses the server duration rather than a fixed city speed',
    () async {
      final client = MockClient(
        (r) async => http.Response(jsonEncode(route()), 200),
      );
      final result = await RoutingService(client: client)
          .buildRoute(start: start, end: end, activity: ActivityType.driving);
      expect(result.durationMin, 6);
    },
  );
  test('an unreachable waypoint has a clear actionable error', () async {
    await expectLater(
      request({'code': 'NoSegment'}, status: 400),
      throwsA(
        isA<RoutingException>().having(
          (e) => e.message,
          'message',
          contains('Переместите точку'),
        ),
      ),
    );
  });
  test('a missing connection is different from a server failure', () async {
    await expectLater(
      request({'code': 'NoRoute'}, status: 400),
      throwsA(
        isA<RoutingException>().having(
          (e) => e.message,
          'message',
          contains('нет доступного маршрута'),
        ),
      ),
    );
  });
  test('bad server JSON never leaks a parser exception', () async {
    await expectLater(
      request('<html>Error</html>'),
      throwsA(isA<RoutingException>()),
    );
  });
  test('remote snapping cannot silently move the destination', () async {
    final data = route();
    data['waypoints'] = [
      {
        'distance': 0,
        'location': [85.2, 52.54],
      },
      {
        'distance': 5000,
        'location': [85.201, 52.541],
      },
    ];
    await expectLater(request(data), throwsA(isA<RoutingException>()));
  });
  test('invalid route geometry is rejected', () async {
    final data = route();
    data['routes'][0]['geometry']['coordinates'] = [
      [85.2, 52.54],
      [190.0, 100.0],
    ];
    await expectLater(request(data), throwsA(isA<RoutingException>()));
  });
  test('changing sport while routing rejects the old graph response', () async {
    final pending = PendingRouting();
    final controller = MapNavigationController(routingService: pending);
    controller.setFinishPoint(end, 'Finish');
    final building = controller.buildRoute();
    controller.setSportMode(SportMode.walking);
    pending.result.complete(
      RoutingResult(
        points: [start, end],
        steps: [],
        distanceKm: 1,
        durationMin: 5,
      ),
    );
    await building;
    expect(controller.routePoints, isEmpty);
    expect(controller.isLoadingRoute, isFalse);
    expect(controller.selectedActivity, ActivityType.hiking);
    controller.dispose();
  });
}
