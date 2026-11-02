import 'saved_route.dart';

class CommunityWeekActivity {
  const CommunityWeekActivity({
    required this.start,
    required this.count,
    required this.distanceKm,
    required this.activeSeconds,
  });
  final DateTime start;
  final int count;
  final double? distanceKm;
  final int? activeSeconds;
  DateTime get end => DateTime(start.year, start.month, start.day + 6);
  factory CommunityWeekActivity.fromHistory(
    Iterable<SavedRoute> rides, {
    required DateTime now,
  }) {
    final local = now.toLocal();
    final today = DateTime(local.year, local.month, local.day);
    final start = DateTime(
      today.year,
      today.month,
      today.day - today.weekday + 1,
    );
    final end = DateTime(start.year, start.month, start.day + 7);
    var count = 0, distances = 0, durations = 0, seconds = 0;
    var km = 0.0;
    final seen = <String>{};
    for (final ride in rides) {
      final recorded = ride.recordedDateTime;
      if (recorded != null && recorded.isAfter(now)) continue;
      final date =
          DateTime.tryParse(ride.activityLocalDay ?? '') ?? recorded?.toLocal();
      if (date == null) continue;
      final day = DateTime(date.year, date.month, date.day);
      if (day.isBefore(start) || !day.isBefore(end) || day.isAfter(today))
        continue;
      final id = ride.remoteId ?? ride.localId;
      if (!seen.add(id)) continue;
      count++;
      final distance = ride.distanceKm;
      if ((ride.distanceMeters != null ||
              RegExp(r'[0-9]').hasMatch(ride.distance)) &&
          distance.isFinite &&
          distance >= 0) {
        distances++;
        km += distance;
      }
      final duration = ride.durationMin;
      if ((ride.durationSeconds != null ||
              RegExp(r'[0-9]').hasMatch(ride.duration)) &&
          duration.isFinite &&
          duration >= 0) {
        durations++;
        seconds += (duration * 60).round();
      }
    }
    return CommunityWeekActivity(
      start: start,
      count: count,
      distanceKm: count == 0
          ? 0
          : distances == count
          ? km
          : null,
      activeSeconds: count == 0
          ? 0
          : durations == count
          ? seconds
          : null,
    );
  }
}
