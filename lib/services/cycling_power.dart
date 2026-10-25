import 'dart:math' as math;

import '../models/workout_details.dart';

/// Simplified steady-state road-load model. No wind or acceleration sensor.
class CyclingPower {
  static double? estimate({
    required double speedKmh,
    required double riderKg,
    required double bikeKg,
    double? gradePercent,
    double cargoKg = 0,
    double cda = .45,
    double crr = .008,
  }) {
    if (!speedKmh.isFinite ||
        !riderKg.isFinite ||
        !bikeKg.isFinite ||
        speedKmh < 0 ||
        speedKmh > 80 ||
        riderKg < 20 ||
        riderKg > 250 ||
        bikeKg < 3 ||
        bikeKg > 80 ||
        !cargoKg.isFinite ||
        cargoKg < 0 ||
        cargoKg > 60 ||
        !cda.isFinite ||
        cda < .2 ||
        cda > .8 ||
        !crr.isFinite ||
        crr < .002 ||
        crr > .03) {
      return null;
    }
    if (gradePercent != null &&
        (!gradePercent.isFinite || gradePercent.abs() > 20)) {
      return null;
    }
    final speed = speedKmh / 3.6;
    final slope = math.atan((gradePercent ?? 0) / 100);
    final gravity = (riderKg + bikeKg + cargoKg) * 9.80665;
    // Fixed reference posture/rolling assumptions, versioned in the ride.
    final watts =
        (gravity * (crr * math.cos(slope) + math.sin(slope)) * speed +
            .5 * 1.225 * cda * speed * speed * speed) /
        .97;
    if (!watts.isFinite || watts > 2500) return null;
    return math.max(0, watts);
  }
}

class PowerInterval {
  const PowerInterval(this.start, this.end, this.a, this.b, this.block);
  final int start, end;
  final double a, b;
  final int block;
  double energy(int from, int to) {
    final duration = end - start;
    final pa = a + (b - a) * (from - start) / duration;
    final pb = a + (b - a) * (to - start) / duration;
    return (pa + pb) / 2 * (to - from);
  }
}

class PowerSummary {
  PowerSummary._(this.intervals, this.coveredSeconds, this.energyJoules);
  static final _cache = Expando<PowerSummary>();
  final List<PowerInterval> intervals;
  final int coveredSeconds;
  final double energyJoules;
  double? get averageWatts =>
      coveredSeconds > 0 ? energyJoules / coveredSeconds : null;
  static PowerSummary of(WorkoutDetails details) =>
      _cache[details] ??= fromSamples(details.samples);
  static bool continuous(WorkoutSample a, WorkoutSample b) {
    final dt = b.activeSeconds - a.activeSeconds;
    if (dt <= 0 || dt > 15 || a.speedKmh == null || b.speedKmh == null) {
      return false;
    }
    final wa = a.elapsedSeconds, wb = b.elapsedSeconds;
    return wa != null && wb != null && wb >= wa && (wb - wa - dt).abs() <= 2;
  }

  static PowerSummary fromSamples(List<WorkoutSample> samples) {
    final intervals = <PowerInterval>[];
    var seconds = 0;
    var energy = 0.0;
    var block = 0;
    for (var i = 1; i < samples.length; i++) {
      final a = samples[i - 1], b = samples[i];
      if (!continuous(a, b) ||
          a.estimatedWatts == null ||
          b.estimatedWatts == null) {
        block++;
        continue;
      }
      final edge = PowerInterval(
        a.activeSeconds,
        b.activeSeconds,
        a.estimatedWatts!,
        b.estimatedWatts!,
        block,
      );
      intervals.add(edge);
      seconds += edge.end - edge.start;
      energy += edge.energy(edge.start, edge.end);
    }
    return PowerSummary._(intervals, seconds, energy);
  }

  final Map<int, double?> _best = {};
  double? bestAverage(int seconds) => _best.putIfAbsent(seconds, () {
    if (seconds <= 0) return null;
    double? best;
    for (var i = 0; i < intervals.length; i++) {
      final end = intervals[i].end;
      var cursor = end;
      var energy = 0.0;
      for (var j = i; j >= 0 && cursor > end - seconds; j--) {
        final edge = intervals[j];
        if (edge.end != cursor || edge.block != intervals[i].block) break;
        final from = math.max(edge.start, end - seconds);
        energy += edge.energy(from, cursor);
        cursor = from;
      }
      if (cursor == end - seconds) {
        final average = energy / seconds;
        if (best == null || average > best) best = average;
      }
    }
    return best;
  });
}
