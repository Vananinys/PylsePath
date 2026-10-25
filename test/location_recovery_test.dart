import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/models/gps_signal.dart';

class PhoneLocation extends GeolocatorPlatform {
  bool enabled = true;
  LocationPermission permission = LocationPermission.whileInUse;
  int requests = 0, subscriptions = 0;
  final status = StreamController<ServiceStatus>.broadcast();
  final positions = StreamController<Position>.broadcast();
  Completer<Position>? pending;
  Position fix() => Position(
    latitude: 56.48,
    longitude: 84.95,
    timestamp: DateTime.now(),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 1,
    heading: 0,
    headingAccuracy: 1,
    speed: 0,
    speedAccuracy: 1,
  );
  @override
  Future<bool> isLocationServiceEnabled() async => enabled;
  @override
  Future<LocationPermission> checkPermission() async => permission;
  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return permission;
  }

  @override
  Stream<ServiceStatus> getServiceStatusStream() => status.stream;
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    subscriptions++;
    return positions.stream;
  }

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async => pending == null ? fix() : pending!.future;
  Future<void> close() async {
    await status.close();
    await positions.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PhoneLocation phone;
  late MapNavigationController controller;
  late GeolocatorPlatform original;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    original = GeolocatorPlatform.instance;
    phone = PhoneLocation();
    GeolocatorPlatform.instance = phone;
    controller = MapNavigationController();
  });
  tearDown(() async {
    controller.dispose();
    await phone.close();
    GeolocatorPlatform.instance = original;
  });
  test(
    'turning location on recovers without recreating controller or app',
    () async {
      phone.enabled = false;
      await expectLater(controller.initLocationTracking(), throwsException);
      expect(controller.gpsSignal.value.quality, GpsQuality.lost);
      phone.enabled = true;
      phone.status.add(ServiceStatus.enabled);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.currentLocation.latitude, 56.48);
      expect(controller.gpsSignal.value.quality, GpsQuality.good);
      expect(phone.subscriptions, 1);
    },
  );
  test('return from permissions settings retries silently', () async {
    phone.permission = LocationPermission.denied;
    await controller.resumeLocationTracking();
    expect(phone.requests, 0);
    phone.permission = LocationPermission.whileInUse;
    await controller.resumeLocationTracking();
    expect(controller.gpsSignal.value.quality, GpsQuality.good);
    expect(phone.requests, 0);
  });
  test(
    'concurrent retries share one subscription and one pending fix',
    () async {
      phone.pending = Completer<Position>();
      final first = controller.initLocationTracking();
      final second = controller.initLocationTracking();
      await Future<void>.delayed(Duration.zero);
      expect(phone.subscriptions, 1);
      phone.pending!.complete(phone.fix());
      await Future.wait([first, second]);
      expect(phone.subscriptions, 1);
    },
  );
  test('stream survives failure of initial one-shot location', () async {
    phone.pending = Completer<Position>();
    final first = controller.initLocationTracking();
    await Future<void>.delayed(Duration.zero);
    phone.pending!.completeError(StateError('first fix failed'));
    await first;
    phone.positions.add(phone.fix());
    await Future<void>.delayed(Duration.zero);
    expect(controller.gpsSignal.value.quality, GpsQuality.good);
  });
  test(
    'stream restart before the first fix keeps location collection alive',
    () async {
      phone.pending = Completer<Position>();
      final initial = controller.initLocationTracking();
      await Future<void>.delayed(Duration.zero);
      await controller.restartPositionStream();
      expect(phone.subscriptions, 2);
      phone.positions.add(phone.fix());
      await Future<void>.delayed(Duration.zero);
      expect(controller.gpsSignal.value.quality, GpsQuality.good);
      phone.pending!.complete(phone.fix());
      await initial;
    },
  );
}
