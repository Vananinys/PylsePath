import '../models/saved_route.dart';
import '../models/workout_details.dart';
import 'cycling_power.dart';

class PersonalRecord {
  const PersonalRecord(
    this.key,
    this.title,
    this.value,
    this.unit,
    this.ride, {
    this.lowerIsBetter = false,
  });
  final String key, title, unit;
  final double value;
  final SavedRoute ride;
  final bool lowerIsBetter;
  String get formatted => unit == 'time'
      ? workoutTime(Duration(seconds: value.round()))
      : unit == 'Вт ≈'
      ? '≈ ${value.round()} Вт'
      : '${value.toStringAsFixed(unit == 'км' || unit == 'км/ч' ? 1 : 0)} $unit';
}

class PersonalRecords {
  static final _distanceCache = Expando<Map<int, double?>>();
  static double? fastestDistance(WorkoutDetails details, int meters) {
    final cache = _distanceCache[details] ??= <int, double?>{};
    return cache.putIfAbsent(meters, () {
      final s = details.samples;
      double? best;
      var start = 0;
      while (start < s.length) {
        var last = start;
        while (last + 1 < s.length &&
            PowerSummary.continuous(s[last], s[last + 1]) &&
            s[last + 1].distanceMeters >= s[last].distanceMeters) {
          last++;
        }
        var end = start + 1;
        for (var i = start; i < last; i++) {
          if (end <= i) end = i + 1;
          while (end <= last &&
              s[end].distanceMeters - s[i].distanceMeters < meters) {
            end++;
          }
          if (end > last) break;
          final a = s[end - 1], b = s[end];
          final span = b.distanceMeters - a.distanceMeters;
          if (span <= 0) continue;
          final fraction =
              (s[i].distanceMeters + meters - a.distanceMeters) / span;
          final seconds =
              a.activeSeconds +
              (b.activeSeconds - a.activeSeconds) * fraction -
              s[i].activeSeconds;
          if (seconds > 0 && (best == null || seconds < best)) best = seconds;
        }
        start = last + 1;
      }
      return best;
    });
  }

  static List<PersonalRecord> calculate(List<SavedRoute> rides) {
    final best = <String, PersonalRecord>{};
    void add(PersonalRecord r) {
      if (!r.value.isFinite || r.value <= 0) return;
      final previous = best[r.key];
      if (previous == null ||
          (r.lowerIsBetter
              ? r.value < previous.value
              : r.value > previous.value)) {
        best[r.key] = r;
      }
    }

    for (final ride in rides) {
      final seconds = ride.durationSeconds ?? (ride.durationMin * 60).round();
      if (seconds > 0)
        add(
          PersonalRecord(
            'average_speed',
            'Лучшая средняя скорость',
            ride.distanceKm / seconds * 3600,
            'км/ч',
            ride,
          ),
        );
      add(
        PersonalRecord(
          'distance',
          'Самая длинная тренировка',
          ride.distanceKm,
          'км',
          ride,
        ),
      );
      add(
        PersonalRecord(
          'duration',
          'Самая продолжительная тренировка',
          (ride.durationSeconds ?? (ride.durationMin * 60).round()).toDouble(),
          'time',
          ride,
        ),
      );
      add(
        PersonalRecord(
          'climb',
          'Наибольший набор высоты',
          ride.elevationGainMeters,
          'м',
          ride,
        ),
      );
      for (final km in [5, 10]) {
        final time = fastestDistance(ride.workoutDetails, km * 1000);
        if (time != null) {
          add(
            PersonalRecord(
              'time_$km',
              'Лучшее время на $km км',
              time,
              'time',
              ride,
              lowerIsBetter: true,
            ),
          );
        }
      }
      if (ride.workoutDetails.powerModel?['version'] != 1 ||
          ride.activityType.isFoot) {
        continue;
      }
      final power = PowerSummary.of(ride.workoutDetails);
      for (final seconds in [60, 300, 1200]) {
        final watts = power.bestAverage(seconds);
        if (watts != null) {
          add(
            PersonalRecord(
              'power_$seconds',
              'Расчётная мощность · ${seconds ~/ 60} мин',
              watts,
              'Вт ≈',
              ride,
            ),
          );
        }
      }
    }
    return best.values.toList();
  }

  static List<String> newRecords(List<SavedRoute> history, SavedRoute ride) {
    final prior = calculate(
      history
          .where(
            (r) =>
                r.activityType == ride.activityType &&
                r.localId != ride.localId,
          )
          .toList(),
    );
    final current = calculate([ride]);
    final result = <String>[];
    for (final r in current) {
      final old = prior.where((p) => p.key == r.key).firstOrNull;
      if (old == null ||
          (r.lowerIsBetter
              ? r.value < old.value - .5
              : r.value > old.value + .5)) {
        result.add('${r.title}: ${r.formatted}');
      }
    }
    return result;
  }
}
