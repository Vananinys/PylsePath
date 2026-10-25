import '../models/activity_type.dart';
import '../models/bike_setup.dart';

/// Gross energy estimate, not a power-meter or heart-rate measurement.
/// Speed bands / electric assistance: 2024 Adult Compendium, Bicycling.
/// https://pacompendium.com/bicycling/
class CyclingEnergy {
  static bool supports(ActivityType activity) =>
      !activity.isFoot && activity != ActivityType.driving;
  static double rate({
    required double riderKg,
    required double speedKmh,
    bool ebike = false,
    BikeSetup setup = const BikeSetup(),
  }) {
    if (!riderKg.isFinite ||
        riderKg < 20 ||
        riderKg > 250 ||
        !speedKmh.isFinite ||
        speedKmh < 0) {
      return 0;
    }
    double met;
    if (speedKmh < 2) {
      met = 1.5;
    } else if (ebike) {
      met = switch (setup.assistance) {
        'off' => 6.8,
        'high' => 4.0,
        _ => 6.0,
      };
    } else {
      met = switch (speedKmh) {
        < 16.09 => 4.0,
        < 19.31 => 6.8,
        < 22.53 => 8.0,
        < 25.75 => 10.0,
        < 32.19 => 12.0,
        _ => 16.8,
      };
    }
    // Standard MET conversion: kcal/min = MET * 3.5 * kg / 200.
    return met * 3.5 * riderKg / 200 * 60;
  }
}
