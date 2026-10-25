import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/services/routing_service.dart';

void main() {
  test(
    'Round trip refines an oversized road route toward the requested distance',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response(
          jsonEncode({
            'code': 'Ok',
            'routes': [
              {
                'distance': calls == 1 ? 70000 : 43000,
                'duration': 7200,
                'geometry': {
                  'coordinates': [
                    [85, 55],
                    [85.1, 55.1],
                    [85, 55],
                  ],
                },
                'legs': <dynamic>[],
              },
            ],
          }),
          200,
        );
      });
      final result = await RoutingService(client: client).buildRoundTrip(
        start: const LatLng(55, 85),
        distanceKm: 43,
        bearing: 90,
        activity: ActivityType.cycling,
      );
      expect(calls, 2);
      expect(result.route.distanceKm, 43);
      client.close();
    },
  );
  test('A round trip sends via points to the bicycle graph and preserves progress offsets', () async {
    const start = LatLng(56.48, 84.95);
    final via = RoutingService.roundTripWaypoints(start, 10, 90);
    expect(via.length, 2);
    expect(via.every((p) => p.longitude > start.longitude), isTrue);
    final client = MockClient((request) async {
      expect(request.url.host, 'routing.openstreetmap.de');
      expect(request.url.path, startsWith('/routed-bike/route/v1/driving/'));
      final coords = request.url.pathSegments.last.split(';');
      expect(coords.length, 4);
      expect(coords.first, coords.last);
      expect(request.url.queryParameters['steps'], 'true');
      return http.Response(
        jsonEncode({
          'code': 'Ok',
          'routes': [
            {
              'distance': 10000,
              'geometry': {
                'coordinates': [
                  [84.95, 56.48],
                  [85.0, 56.5],
                  [84.95, 56.48],
                ],
              },
              'legs': [
                for (var i = 0; i < 3; i++)
                  {
                    'distance': i == 2 ? 4000 : 3000,
                    'steps': [
                      {
                        'distance': i == 2 ? 4000 : 3000,
                        'name': '',
                        'maneuver': {
                          'type': i == 0 ? 'depart' : 'turn',
                          'modifier': 'right',
                          'location': [84.95, 56.48],
                        },
                      },
                    ],
                  },
              ],
            },
          ],
        }),
        200,
      );
    });
    final result = await RoutingService(client: client).buildRoute(
      start: start,
      end: start,
      via: via,
      activity: ActivityType.cycling,
    );
    expect(result.distanceKm, 10);
    expect(result.viaOffsetsMeters, [3000, 6000]);
    expect(result.steps.map((s) => s.routeOffsetMeters), [0, 3000, 6000]);
    client.close();
  });

  test('Invalid loop distance fails before making a request', () {
    expect(
      () => RoutingService.roundTripWaypoints(const LatLng(56, 85), 0, 90),
      throwsArgumentError,
    );
  });
}
