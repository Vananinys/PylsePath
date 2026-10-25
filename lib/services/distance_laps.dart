import '../models/workout_details.dart';

/// Fixed distance laps use active time. Only the boundary between two
/// distance observations is interpolated; paused wall time never enters it.
class DistanceLaps {
  DistanceLaps(this.meters, {List<WorkoutLap> completed = const []})
    : laps = List.of(completed);
  final int meters;
  final List<WorkoutLap> laps;
  double _previousMeters = 0;
  int _previousMilliseconds = 0;

  void seed(double distance, Duration active) {
    _previousMeters = distance;
    _previousMilliseconds = active.inMilliseconds;
  }

  List<WorkoutLap> update(double distance, Duration active) {
    if (meters <= 0 ||
        !distance.isFinite ||
        distance < _previousMeters ||
        active.inMilliseconds < _previousMilliseconds) {
      return const [];
    }
    final added = <WorkoutLap>[];
    final span = distance - _previousMeters;
    var boundary = (laps.length + 1) * meters;
    while (span > 0 && boundary <= distance && laps.length < 1000) {
      final fraction = ((boundary - _previousMeters) / span).clamp(0.0, 1.0);
      final end =
          ((_previousMilliseconds +
                      (active.inMilliseconds - _previousMilliseconds) *
                          fraction) /
                  1000)
              .round();
      final previousEnd = laps.lastOrNull?.endSeconds ?? 0;
      final lap = WorkoutLap(
        number: laps.length + 1,
        distanceMeters: meters.toDouble(),
        activeSeconds: (end - previousEnd).clamp(0, 2147483647),
        endSeconds: end,
      );
      laps.add(lap);
      added.add(lap);
      boundary = (laps.length + 1) * meters;
    }
    seed(distance, active);
    return added;
  }
}
