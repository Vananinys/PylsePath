import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/models/gps_signal.dart';

void main() {
  final now = DateTime.utc(2026, 10, 17);

  test('No fix starts searching; errors report loss', () {
    expect(const GpsSignal().checkedAt(now).quality, GpsQuality.searching);
    expect(const GpsSignal(unavailable: true).quality, GpsQuality.lost);
  });

  test('Accuracy boundaries and invalid accuracy', () {
    for (final accuracy in [0.0, 20.0]) {
      expect(
        GpsSignal(accuracy: accuracy, updatedAt: now).quality,
        GpsQuality.good,
      );
    }
    for (final accuracy in [20.1, -1.0, double.nan, double.infinity]) {
      expect(
        GpsSignal(accuracy: accuracy, updatedAt: now).quality,
        GpsQuality.weak,
      );
    }
  });

  test('Stale fixes become lost and fresh fixes recover', () {
    final signal = GpsSignal(accuracy: 5, updatedAt: now);
    expect(
      signal.checkedAt(now.add(const Duration(seconds: 29))).quality,
      GpsQuality.good,
    );
    expect(
      signal.checkedAt(now.add(const Duration(seconds: 30))).quality,
      GpsQuality.lost,
    );
    expect(
      GpsSignal(
        accuracy: 5,
        updatedAt: now.add(const Duration(seconds: 31)),
      ).checkedAt(now.add(const Duration(seconds: 31))).quality,
      GpsQuality.good,
    );
  });
}
