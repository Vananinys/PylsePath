import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/models/route_step.dart';

Position _fix(double longitude, int seconds) => Position(
  latitude: 55,
  longitude: longitude,
  timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: seconds)),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 1,
  heading: 0,
  headingAccuracy: 1,
  speed: 5,
  speedAccuracy: 1,
);

RouteStep _step(double longitude, double offset) => RouteStep(
  instruction: 'Манёвр',
  streetName: '',
  icon: Icons.turn_right,
  location: LatLng(55, longitude),
  distance: 100,
  routeOffsetMeters: offset,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('route guidance advances across skipped fixes and never goes backward', () {
    final controller = MapNavigationController()
      ..setRouteForTesting(
        points: const [LatLng(55, 83), LatLng(55, 83.004)],
        steps: [_step(83, 0), _step(83.0015, 100), _step(83.003, 200)],
      )
      ..setNavigating(true);

    controller.applyGpsSampleForTesting(_fix(83.0003, 1));
    expect(controller.currentStepIndex, 1);

    // A sparse GPS stream can jump past the maneuver coordinate entirely.
    controller.applyGpsSampleForTesting(_fix(83.002, 2));
    expect(controller.currentStepIndex, 2);

    // A noisy fix behind the rider cannot restore an earlier instruction.
    controller.applyGpsSampleForTesting(_fix(83.001, 3));
    expect(controller.currentStepIndex, 2);
    controller.dispose();
  });
}
