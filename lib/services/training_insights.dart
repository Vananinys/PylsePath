import '../models/activity_type.dart';
import '../models/saved_route.dart';

enum TrainingSport { all, cycling, running, walking }

extension TrainingSportInfo on TrainingSport {
  String get label => switch (this) {
    TrainingSport.all => 'Все занятия',
    TrainingSport.cycling => 'Велосипед',
    TrainingSport.running => 'Бег',
    TrainingSport.walking => 'Ходьба',
  };

  bool accepts(SavedRoute ride) => switch (this) {
    TrainingSport.all => ride.activityType != ActivityType.driving,
    TrainingSport.cycling =>
      !ride.activityType.isFoot && ride.activityType != ActivityType.driving,
    TrainingSport.running => ride.activityType.isRunning,
    TrainingSport.walking =>
      ride.activityType.isFoot && !ride.activityType.isRunning,
  };
}

DateTime trainingDay(DateTime date) {
  final local = date.toLocal();
  return DateTime(local.year, local.month, local.day);
}

DateTime trainingWeek(DateTime date) {
  final day = trainingDay(date);
  return DateTime(day.year, day.month, day.day - day.weekday + 1);
}

class TrainingTotals {
  const TrainingTotals({
    this.count = 0,
    this.km = 0,
    this.seconds = 0,
    this.climb = 0,
    this.effortLoad = 0,
    this.effortCount = 0,
    this.activeDays = 0,
  });
  final int count, seconds, effortCount, activeDays;
  final double km, climb, effortLoad;
  double get averageKmh => seconds > 0 ? km / seconds * 3600 : 0;

  factory TrainingTotals.of(Iterable<SavedRoute> rides) {
    var count = 0, seconds = 0, rated = 0;
    var km = 0.0, climb = 0.0, load = 0.0;
    final days = <DateTime>{};
    for (final ride in rides) {
      count++;
      final duration = ride.durationSeconds ?? (ride.durationMin * 60).round();
      seconds += duration;
      km += ride.distanceKm;
      climb += ride.elevationGainMeters;
      days.add(trainingDay(ride.dateTime));
      if (ride.workoutDetails.effort != null && duration > 0) {
        rated++;
        load += duration / 60 * ride.workoutDetails.effort!;
      }
    }
    return TrainingTotals(
      count: count,
      km: km,
      seconds: seconds,
      climb: climb,
      effortLoad: load,
      effortCount: rated,
      activeDays: days.length,
    );
  }
}

class TrainingWeek {
  const TrainingWeek(this.start, this.totals);
  final DateTime start;
  final TrainingTotals totals;
}

/// Calendar arithmetic is local; UTC uploads are grouped by the rider's day.
class TrainingInsights {
  TrainingInsights(
    Iterable<SavedRoute> history, {
    TrainingSport sport = TrainingSport.all,
    DateTime? now,
  }) : now = now ?? DateTime.now(),
       rides = history.where(sport.accepts).toList()
         ..sort((a, b) => b.dateTime.compareTo(a.dateTime));

  final DateTime now;
  final List<SavedRoute> rides;

  List<SavedRoute> between(DateTime start, DateTime end) => rides.where((ride) {
    final date = ride.dateTime.toLocal();
    return !date.isBefore(start) && date.isBefore(end);
  }).toList();

  List<SavedRoute> onDay(DateTime day) {
    final start = trainingDay(day);
    return between(start, DateTime(start.year, start.month, start.day + 1));
  }

  TrainingTotals get thisWeek => TrainingTotals.of(
    between(trainingWeek(now), now.add(const Duration(microseconds: 1))),
  );

  /// Same weekday and local clock time, rather than an entire previous week.
  TrainingTotals get previousWeekToDate {
    final start = trainingWeek(now);
    final end = now.toLocal();
    return TrainingTotals.of(
      between(
        DateTime(start.year, start.month, start.day - 7),
        DateTime(
          end.year,
          end.month,
          end.day - 7,
          end.hour,
          end.minute,
          end.second,
          end.millisecond,
          end.microsecond,
        ),
      ),
    );
  }

  List<TrainingWeek> get weeks {
    final start = trainingWeek(now);
    return List.generate(8, (i) {
      final day = DateTime(start.year, start.month, start.day - (7 - i) * 7);
      final end = DateTime(day.year, day.month, day.day + 7);
      final cutoff = now.add(const Duration(microseconds: 1));
      return TrainingWeek(
        day,
        TrainingTotals.of(between(day, end.isAfter(cutoff) ? cutoff : end)),
      );
    });
  }

  int get consecutiveWeeks {
    final days = rides
        .where((r) => !r.dateTime.isAfter(now))
        .map((r) => trainingWeek(r.dateTime))
        .toSet();
    var week = trainingWeek(now);
    if (!days.contains(week)) {
      week = DateTime(week.year, week.month, week.day - 7);
    }
    var count = 0;
    while (days.contains(week)) {
      count++;
      week = DateTime(week.year, week.month, week.day - 7);
    }
    return count;
  }
}
