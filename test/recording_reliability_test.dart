import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/models/gps_signal.dart';

import 'location_recovery_test.dart' show PhoneLocation;

Position sample(
  DateTime at, {
  double lat = 56.48,
  double speed = 0,
  double speedUncertainty = .1,
}) => Position(
  latitude: lat,
  longitude: 84.95,
  timestamp: at,
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 1,
  heading: 0,
  headingAccuracy: 1,
  speed: speed,
  speedAccuracy: speedUncertainty,
);

class RecoveringPhone extends PhoneLocation {
  final streams = <StreamController<Position>>[];
  DateTime now = DateTime.now();
  double latitude = 56.48;
  @override
  Position fix() => sample(now, lat: latitude);
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    subscriptions++;
    final stream = StreamController<Position>.broadcast();
    streams.add(stream);
    return stream.stream;
  }

  @override
  Future<void> close() async {
    for (final stream in streams) {
      if (!stream.isClosed) await stream.close();
    }
    await super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GeolocatorPlatform original;
  late RecoveringPhone phone;
  late MapNavigationController controller;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    original = GeolocatorPlatform.instance;
    phone = RecoveringPhone();
    GeolocatorPlatform.instance = phone;
    controller = MapNavigationController(gpsNow: () => phone.now);
  });
  tearDown(() async {
    controller.dispose();
    await phone.close();
    GeolocatorPlatform.instance = original;
  });
  Future<void> start() async {
    await controller.initLocationTracking();
    controller.startWorkout();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('Future and stale samples cannot poison the track or freshness', () {
    controller.setAutoPauseEnabled(false);
    controller.startWorkout();
    controller.applyGpsSampleForTesting(
      sample(phone.now.add(const Duration(hours: 1))),
    );
    controller.applyGpsSampleForTesting(
      sample(phone.now.subtract(const Duration(hours: 1))),
    );
    expect(controller.recordedPath, isEmpty);
    expect(controller.gpsSignal.value.updatedAt, isNull);
    controller.applyGpsSampleForTesting(
      sample(phone.now.subtract(const Duration(seconds: 2))),
    );
    controller.applyGpsSampleForTesting(sample(phone.now, lat: 56.48003));
    expect(controller.recordedPath, hasLength(2));
    expect(controller.totalDistanceMeters, greaterThan(0));
    expect(controller.gpsSignal.value.updatedAt, phone.now);
  });
  test('A future timestamp is never considered fresh', () {
    expect(
      GpsSignal(
        accuracy: 5,
        updatedAt: phone.now.add(const Duration(hours: 1)),
      ).checkedAt(phone.now).quality,
      GpsQuality.lost,
    );
  });
  test(
    'A stream error reconnects once and recording continues in a new segment',
    () async {
      await start();
      phone.streams.last.add(sample(phone.now));
      await Future<void>.delayed(Duration.zero);
      final before = phone.subscriptions;
      phone.streams.last.addError(StateError('provider disconnected'));
      phone.streams.last.addError(StateError('repeated provider error'));
      await Future<void>.delayed(const Duration(milliseconds: 1150));
      expect(phone.subscriptions, before + 1);
      phone.now = phone.now.add(const Duration(seconds: 2));
      phone.streams.last.add(sample(phone.now, lat: 56.4801));
      await Future<void>.delayed(Duration.zero);
      expect(controller.recordedSegments.map((s) => s.length), [1, 1]);
      expect(controller.totalDistanceMeters, 0);
    },
  );
  test('A completed stream reconnects during a workout', () async {
    await start();
    final before = phone.subscriptions;
    await phone.streams.last.close();
    await Future<void>.delayed(const Duration(milliseconds: 1150));
    expect(phone.subscriptions, before + 1);
  });
  test(
    'Silence at rest does not restart, but a fresh distant probe does',
    () async {
      await start();
      phone.streams.last.add(sample(phone.now, speed: 3));
      await Future<void>.delayed(Duration.zero);
      final before = phone.subscriptions;
      phone.now = phone.now.add(const Duration(seconds: 60));
      controller.acceptFreshnessProbeForTesting(sample(phone.now));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(phone.subscriptions, before);
      phone.latitude = 56.481;
      phone.now = phone.now.add(const Duration(seconds: 1));
      controller.acceptFreshnessProbeForTesting(
        sample(phone.now, lat: phone.latitude),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1150));
      expect(phone.subscriptions, before + 1);
    },
  );
  test(
    'A stream error without a workout does not start a recovery loop',
    () async {
      await controller.initLocationTracking();
      final before = phone.subscriptions;
      phone.streams.last.addError(StateError('idle'));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(phone.subscriptions, before);
    },
  );
  test(
    'Two accurate fresh stationary probes may pause but never add track points',
    () {
      controller.startWorkout();
      controller.acceptFreshnessProbeForTesting(
        sample(phone.now.subtract(const Duration(seconds: 20))),
      );
      expect(controller.isAutoPaused, isFalse);
      controller.acceptFreshnessProbeForTesting(sample(phone.now));
      expect(controller.isAutoPaused, isTrue);
      expect(controller.recordedPath, isEmpty);
      expect(controller.totalDistanceMeters, 0);
    },
  );
  test('Displaced probes are not evidence of a stop', () {
    controller.startWorkout();
    controller.acceptFreshnessProbeForTesting(
      sample(phone.now.subtract(const Duration(seconds: 20))),
    );
    controller.acceptFreshnessProbeForTesting(sample(phone.now, lat: 56.481));
    expect(controller.isAutoPaused, isFalse);
    expect(controller.recordedPath, isEmpty);
  });
  test('A queued recovery cannot restart a finished recording', () async {
    await start();
    final before = phone.subscriptions;
    phone.streams.last.addError(StateError('finish-race'));
    await Future<void>.delayed(Duration.zero);
    expect(await controller.finishAndSaveWorkout(), isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(phone.subscriptions, before);
    expect(phone.requests, 0);
  });
  test(
    'Unknown or imprecise speed cannot trigger stationary-probe auto-pause',
    () {
      controller.startWorkout();
      for (final uncertainty in [0.0, 2.0]) {
        controller.acceptFreshnessProbeForTesting(
          sample(
            phone.now.subtract(const Duration(seconds: 20)),
            speedUncertainty: uncertainty,
          ),
        );
        controller.acceptFreshnessProbeForTesting(
          sample(phone.now, speedUncertainty: uncertainty),
        );
        expect(controller.isAutoPaused, isFalse);
      }
    },
  );
}
