import 'package:latlong2/latlong.dart';

import 'interval_plan.dart';
import 'walking_steps.dart';
import 'brake_load.dart';
import 'ride_moment.dart';

enum WorkoutGoalKind { distance, duration, calories }

String workoutTime(Duration value) {
  String two(int value) => value.toString().padLeft(2, '0');
  return value.inHours > 0
      ? '${two(value.inHours)}:${two(value.inMinutes % 60)}:${two(value.inSeconds % 60)}'
      : '${two(value.inMinutes)}:${two(value.inSeconds % 60)}';
}

/// Human-readable duration for workout results; live clocks use workoutTime.
String workoutDurationLabel(Duration value) {
  final seconds = value.inSeconds < 0 ? 0 : value.inSeconds;
  if (seconds < 60) return '$seconds сек';
  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;
  if (minutes < 60) {
    return '$minutes мин${remainingSeconds > 0 ? " $remainingSeconds сек" : ""}';
  }
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return '$hours ч${remainingMinutes > 0 ? " $remainingMinutes мин" : ""}';
}

String workoutPace(double meters, Duration active) {
  if (!meters.isFinite || meters < 1 || active.inSeconds <= 0) return '—';
  final seconds = (active.inSeconds / (meters / 1000)).round();
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')} /км';
}

class WorkoutGoal {
  const WorkoutGoal(this.kind, this.target);
  final WorkoutGoalKind kind;

  /// Metres for distance, seconds for duration.
  final double target;
  double progress(double meters, Duration active, {double calories = 0}) =>
      target <= 0
      ? 0
      : ((kind == WorkoutGoalKind.distance
                    ? meters
                    : kind == WorkoutGoalKind.calories
                    ? calories
                    : active.inSeconds) /
                target)
            .clamp(0.0, 1.0);
  String get label => kind == WorkoutGoalKind.calories
      ? '${target.round()} ккал'
      : kind == WorkoutGoalKind.distance
      ? '${(target / 1000).toStringAsFixed(target % 1000 == 0 ? 0 : 1)} км'
      : '${(target / 60).toStringAsFixed(target % 60 == 0 ? 0 : 1)} мин';
  Map<String, dynamic> toJson() => {'kind': kind.name, 'target': target};
  static WorkoutGoal? fromJson(dynamic value) {
    if (value is! Map) return null;
    final kind = WorkoutGoalKind.values
        .where((v) => v.name == value['kind'])
        .firstOrNull;
    final target = value['target'];
    if (kind == null ||
        target is! num ||
        !target.isFinite ||
        target <= 0 ||
        target >
            (kind == WorkoutGoalKind.distance
                ? 500000
                : kind == WorkoutGoalKind.calories
                ? 10000
                : 86400)) {
      return null;
    }
    return WorkoutGoal(kind, target.toDouble());
  }
}

class WorkoutLap {
  const WorkoutLap({
    required this.number,
    required this.distanceMeters,
    required this.activeSeconds,
    required this.endSeconds,
  });
  final int number;
  final double distanceMeters;
  final int activeSeconds;
  final int endSeconds;
  double get speedKmh =>
      activeSeconds > 0 ? distanceMeters / activeSeconds * 3.6 : 0;
  Map<String, dynamic> toJson() => {
    'number': number,
    'meters': distanceMeters,
    'seconds': activeSeconds,
    'end': endSeconds,
  };
  factory WorkoutLap.fromJson(Map value) => WorkoutLap(
    number: (value['number'] as num).toInt(),
    distanceMeters: (value['meters'] as num).toDouble(),
    activeSeconds: (value['seconds'] as num).toInt(),
    endSeconds: (value['end'] as num).toInt(),
  );
}

class WorkoutSample {
  const WorkoutSample({
    required this.activeSeconds,
    required this.distanceMeters,
    this.speedKmh,
    this.estimatedWatts,
    this.powerGradePercent,
    this.elapsedSeconds,
    this.trackPointIndex,
    this.altitudeMeters,
  });
  final int activeSeconds;
  final double distanceMeters;

  /// Null is missing GPS, never an invented zero-speed observation.
  final double? speedKmh;
  final double? estimatedWatts;
  final double? powerGradePercent;
  final int? elapsedSeconds;

  /// Exact link for new recordings; legacy samples replay by track distance.
  final int? trackPointIndex;
  final double? altitudeMeters;
  Map<String, dynamic> toJson() => {
    'seconds': activeSeconds,
    'meters': distanceMeters,
    'speed': speedKmh,
    'estimated_watts': estimatedWatts,
    'power_grade_percent': powerGradePercent,
    'elapsed': elapsedSeconds,
    'track_point_index': trackPointIndex,
    'altitude_meters': altitudeMeters,
  };
  factory WorkoutSample.fromJson(Map value) => WorkoutSample(
    activeSeconds: (value['seconds'] as num).toInt(),
    distanceMeters: (value['meters'] as num).toDouble(),
    speedKmh: (value['speed'] as num?)?.toDouble(),
    estimatedWatts: _validWatts(value['estimated_watts']),
    powerGradePercent: value['power_grade_percent'] is num
        ? (value['power_grade_percent'] as num).toDouble()
        : null,
    elapsedSeconds: (value['elapsed'] as num?)?.toInt(),
    trackPointIndex:
        value['track_point_index'] is int &&
            (value['track_point_index'] as int) >= 0
        ? value['track_point_index'] as int
        : null,
    altitudeMeters:
        value['altitude_meters'] is num &&
            (value['altitude_meters'] as num).isFinite &&
            (value['altitude_meters'] as num) >= -500 &&
            (value['altitude_meters'] as num) <= 9000
        ? (value['altitude_meters'] as num).toDouble()
        : null,
  );
  static double? _validWatts(dynamic v) =>
      v is num && v.isFinite && v >= 0 && v <= 2500 ? v.toDouble() : null;
}

class WorkoutDetails {
  const WorkoutDetails({
    this.goal,
    this.segmentStarts = const [],
    this.laps = const [],
    this.samples = const [],
    this.maxSpeedKmh = 0,
    this.elapsedSeconds = 0,
    this.notes = '',
    this.effort,
    this.calorieRatePerHour,
    this.powerModel,
    this.energyModel,
    this.brakeLoad,
    this.autoLapMeters = 0,
    this.autoLaps = const [],
    this.intervalPlan,
    this.walkingSteps,
    this.rideMoments = const [],
  });
  final List<int> segmentStarts;
  final WorkoutGoal? goal;
  final List<WorkoutLap> laps;
  final List<WorkoutSample> samples;
  final double maxSpeedKmh;
  final int elapsedSeconds;
  final String notes;
  final int? effort;
  final double? calorieRatePerHour;
  final Map<String, dynamic>? powerModel;
  final Map<String, dynamic>? energyModel;
  final BrakeLoad? brakeLoad;
  final int autoLapMeters;
  final List<WorkoutLap> autoLaps;
  final IntervalPlan? intervalPlan;
  final WalkingSteps? walkingSteps;
  final List<RideMoment> rideMoments;
  Map<String, dynamic> toJson() => {
    'segment_starts': segmentStarts,
    'goal': goal?.toJson(),
    'laps': laps.map((v) => v.toJson()).toList(),
    'samples': samples.map((v) => v.toJson()).toList(),
    'max_speed_kmh': maxSpeedKmh,
    'elapsed_seconds': elapsedSeconds,
    'notes': notes,
    'effort': effort,
    'calorie_rate_per_hour': calorieRatePerHour,
    'power_model': powerModel,
    'energy_model': energyModel,
    'brake_load': brakeLoad?.toJson(),
    'auto_lap_meters': autoLapMeters,
    'auto_laps': autoLaps.map((lap) => lap.toJson()).toList(),
    'interval_plan': intervalPlan?.toJson(),
    'walking_steps': walkingSteps?.toJson(),
    'ride_moments': rideMoments.map((moment) => moment.toJson()).toList(),
  };
  static List<List<LatLng>> splitTrack(List<LatLng> points, List<int> starts) {
    if (points.isEmpty) return [];
    final boundaries = {
      0,
      ...starts.where((i) => i > 0 && i < points.length),
      points.length,
    }.toList()..sort();
    return [
      for (var i = 0; i < boundaries.length - 1; i++)
        points.sublist(boundaries[i], boundaries[i + 1]),
    ];
  }

  factory WorkoutDetails.fromJson(dynamic value) {
    if (value is! Map) return const WorkoutDetails();
    final laps = <WorkoutLap>[];
    final autoLaps = <WorkoutLap>[];
    final samples = <WorkoutSample>[];
    for (final raw
        in (value['auto_laps'] is List ? value['auto_laps'] as List : const [])
            .take(1000)) {
      try {
        final lap = WorkoutLap.fromJson(raw as Map);
        if (lap.number == autoLaps.length + 1 &&
            lap.distanceMeters.isFinite &&
            lap.distanceMeters > 0 &&
            lap.activeSeconds >= 0 &&
            lap.endSeconds >= (autoLaps.lastOrNull?.endSeconds ?? 0) &&
            lap.endSeconds - (autoLaps.lastOrNull?.endSeconds ?? 0) ==
                lap.activeSeconds) {
          autoLaps.add(lap);
        }
      } catch (_) {
        // Optional split data must never prevent opening an old workout.
      }
    }
    for (final raw
        in (value['laps'] is List ? value['laps'] as List : const []).take(
          1000,
        )) {
      try {
        final lap = WorkoutLap.fromJson(raw as Map);
        if (lap.number > 0 &&
            lap.activeSeconds >= 0 &&
            lap.endSeconds >= 0 &&
            lap.distanceMeters.isFinite &&
            lap.distanceMeters >= 0) {
          laps.add(lap);
        }
      } catch (_) {
        /* Ignore an invalid optional lap. */
      }
    }
    for (final raw
        in (value['samples'] is List ? value['samples'] as List : const [])
            .take(7200)) {
      try {
        final sample = WorkoutSample.fromJson(raw as Map);
        if (sample.activeSeconds >= 0 &&
            sample.distanceMeters.isFinite &&
            sample.distanceMeters >= 0 &&
            (sample.speedKmh == null ||
                (sample.speedKmh!.isFinite &&
                    sample.speedKmh! >= 0 &&
                    sample.speedKmh! <= 300))) {
          samples.add(sample);
        }
      } catch (_) {
        /* Optional telemetry must not hide the ride. */
      }
    }
    final speed = value['max_speed_kmh'];
    final elapsed = value['elapsed_seconds'];
    final effort = value['effort'];
    final calorieRate = value['calorie_rate_per_hour'];
    return WorkoutDetails(
      rideMoments: value['ride_moments'] is List
          ? List.unmodifiable(
              (value['ride_moments'] as List)
                  .take(200)
                  .map(RideMoment.tryParse)
                  .whereType<RideMoment>(),
            )
          : const [],
      walkingSteps: WalkingSteps.fromJson(value['walking_steps']),
      intervalPlan: IntervalPlan.fromJson(value['interval_plan']),
      segmentStarts: value['segment_starts'] is List
          ? (value['segment_starts'] as List)
                .whereType<int>()
                .where((i) => i >= 0)
                .take(10000)
                .toList()
          : const [],
      goal: WorkoutGoal.fromJson(value['goal']),
      laps: List.unmodifiable(laps),
      samples: List.unmodifiable(samples),
      maxSpeedKmh: speed is num && speed.isFinite && speed >= 0 && speed <= 300
          ? speed.toDouble()
          : 0,
      elapsedSeconds: elapsed is num && elapsed.isFinite && elapsed >= 0
          ? elapsed.toInt()
          : 0,
      notes: value['notes'] is String
          ? (value['notes'] as String).substring(
              0,
              (value['notes'] as String).length.clamp(0, 2000),
            )
          : '',
      effort: effort is int && effort >= 1 && effort <= 10 ? effort : null,
      calorieRatePerHour:
          calorieRate is num &&
              calorieRate.isFinite &&
              calorieRate >= 0 &&
              calorieRate <= 5000
          ? calorieRate.toDouble()
          : null,
      powerModel: value['power_model'] is Map
          ? Map<String, dynamic>.from(value['power_model'] as Map)
          : null,
      energyModel: value['energy_model'] is Map
          ? Map<String, dynamic>.from(value['energy_model'] as Map)
          : null,
      brakeLoad: BrakeLoad.fromJson(value['brake_load']),
      autoLapMeters: [1000, 5000, 10000].contains(value['auto_lap_meters'])
          ? value['auto_lap_meters'] as int
          : 0,
      autoLaps: List.unmodifiable(autoLaps),
    );
  }
}
