import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pulsepath/models/gps_signal.dart';
import 'package:pulsepath/services/gps_freshness_probe.dart';

Position fix(DateTime at, {double accuracy = 5}) => Position(
  latitude: 55,
  longitude: 37,
  timestamp: at,
  accuracy: accuracy,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);
void main() {
  test(
    'Stationary real fix refreshes signal without manufacturing a track sample',
    () async {
      final now = DateTime.now();
      var signal = GpsSignal(
        accuracy: 5,
        updatedAt: now.subtract(const Duration(seconds: 21)),
      );
      var reads = 0;
      var accepted = 0;
      final probe = GpsFreshnessProbe(
        read: () async {
          reads++;
          return fix(now);
        },
        current: () => signal,
        accept: (p) {
          accepted++;
          signal = GpsSignal(accuracy: p.accuracy, updatedAt: p.timestamp);
        },
      );
      await probe.check(now);
      expect(reads, 1);
      expect(accepted, 1);
      expect(signal.checkedAt(now).quality, GpsQuality.good);
      await probe.check(now.add(const Duration(seconds: 19)));
      expect(reads, 1);
      probe.dispose();
    },
  );
  test(
    'Failed or cached old request cannot conceal real signal loss',
    () async {
      final now = DateTime.now();
      final signal = GpsSignal(
        accuracy: 5,
        updatedAt: now.subtract(const Duration(seconds: 35)),
      );
      var accepts = 0;
      var failed = true;
      final probe = GpsFreshnessProbe(
        read: () async {
          if (failed) throw TimeoutException('no fix');
          return fix(signal.updatedAt!);
        },
        current: () => signal,
        accept: (_) => accepts++,
      );
      await probe.check(now);
      failed = false;
      await probe.check(now.add(const Duration(seconds: 21)));
      expect(accepts, 0);
      expect(signal.checkedAt(now).quality, GpsQuality.lost);
      probe.dispose();
    },
  );
  test(
    'No overlap, no background request, no overwriting a newer streamed fix',
    () async {
      final now = DateTime.now();
      var signal = GpsSignal(
        accuracy: 5,
        updatedAt: now.subtract(const Duration(seconds: 21)),
      );
      final pending = Completer<Position>();
      var reads = 0;
      var accepts = 0;
      final probe = GpsFreshnessProbe(
        read: () {
          reads++;
          return pending.future;
        },
        current: () => signal,
        accept: (_) => accepts++,
      );
      await probe.check(now, enabled: false);
      expect(reads, 0);
      final first = probe.check(now);
      await probe.check(now);
      expect(reads, 1);
      signal = GpsSignal(accuracy: 5, updatedAt: now);
      pending.complete(fix(now.subtract(const Duration(seconds: 1))));
      await first;
      expect(accepts, 0);
      probe.dispose();
    },
  );
  test(
    'Weak accuracy remains weak and disposal ignores pending result',
    () async {
      final now = DateTime.now();
      var signal = GpsSignal(
        accuracy: 5,
        updatedAt: now.subtract(const Duration(seconds: 21)),
      );
      final probe = GpsFreshnessProbe(
        read: () async => fix(now, accuracy: 80),
        current: () => signal,
        accept: (p) =>
            signal = GpsSignal(accuracy: p.accuracy, updatedAt: p.timestamp),
      );
      await probe.check(now);
      expect(signal.quality, GpsQuality.weak);
      probe.dispose();
      final pending = Completer<Position>();
      var accepted = false;
      final disposed = GpsFreshnessProbe(
        read: () => pending.future,
        current: () =>
            GpsSignal(updatedAt: now.subtract(const Duration(seconds: 21))),
        accept: (_) => accepted = true,
      );
      final future = disposed.check(now);
      disposed.dispose();
      pending.complete(fix(now));
      await future;
      expect(accepted, false);
    },
  );
}
