import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/saved_route.dart';
import '../data/account_progress_cache.dart';

class ActivityTotals {
  const ActivityTotals({
    this.rides = 0,
    this.km = 0,
    this.seconds = 0,
    this.climb = 0,
    this.physicalKm = 0,
    this.physicalSeconds = 0,
  });
  final int rides, seconds, physicalSeconds;
  final double km, climb, physicalKm;
  factory ActivityTotals.fromJson(Map<String, dynamic> row) => ActivityTotals(
    rides: (row['rides'] as num?)?.toInt() ?? 0,
    km: (row['distance_km'] as num?)?.toDouble() ?? 0,
    seconds: (row['duration_seconds'] as num?)?.toInt() ?? 0,
    climb: (row['climb_m'] as num?)?.toDouble() ?? 0,
    physicalKm: (row['physical_km'] as num?)?.toDouble() ?? 0,
    physicalSeconds: (row['physical_seconds'] as num?)?.toInt() ?? 0,
  );
  String get duration => seconds < 3600
      ? '${seconds ~/ 60} мин'
      : '${seconds ~/ 3600} ч ${seconds % 3600 ~/ 60} мин';
}

class ActivitySummary {
  const ActivitySummary({
    required this.day,
    this.visible = true,
    this.streak = 0,
    this.best = 0,
    this.activeToday = false,
    this.activeDays = 0,
    this.today = const ActivityTotals(),
    this.total = const ActivityTotals(),
    this.week = const [],
  });
  final DateTime day;
  final bool visible, activeToday;
  final int streak, best, activeDays;
  final ActivityTotals today, total;
  final List<bool> week;
  double get dayProgress => activeToday
      ? 1
      : (today.physicalKm > today.physicalSeconds / 600
                ? today.physicalKm
                : today.physicalSeconds / 600)
            .clamp(0, 1);
  factory ActivitySummary.fromJson(Map<String, dynamic> row) => ActivitySummary(
    day: DateTime.tryParse(row['day']?.toString() ?? '') ?? DateTime.now(),
    visible: row['visible'] != false,
    streak: (row['current_streak'] as num?)?.toInt() ?? 0,
    best: (row['best_streak'] as num?)?.toInt() ?? 0,
    activeToday: row['active_today'] == true,
    activeDays: (row['active_days'] as num?)?.toInt() ?? 0,
    today: ActivityTotals.fromJson(
      Map<String, dynamic>.from(row['today'] as Map? ?? {}),
    ),
    total: ActivityTotals.fromJson(
      Map<String, dynamic>.from(row['all_time'] as Map? ?? {}),
    ),
    week: (row['week'] as List? ?? [])
        .map((d) => (d as Map)['active'] == true)
        .toList(),
  );

  factory ActivitySummary.fromRides(List<SavedRoute> rides, {DateTime? now}) {
    final clock = (now ?? DateTime.now()).toLocal();
    DateTime dayOf(DateTime d) {
      final l = d.toLocal();
      return DateTime.utc(l.year, l.month, l.day);
    }

    final todayKey = dayOf(clock);
    final groups = <DateTime, List<SavedRoute>>{};
    final allRows = <SavedRoute>[];
    for (final r in rides) {
      final recorded = DateTime.tryParse(r.activityLocalDay ?? '');
      final timestamp = r.recordedDateTime;
      if (recorded == null && timestamp == null) {
        allRows.add(r);
        continue;
      }
      final date = recorded == null
          ? dayOf(r.dateTime)
          : DateTime.utc(recorded.year, recorded.month, recorded.day);
      if (date.isAfter(todayKey) ||
          r.dateTime.isAfter(clock.add(const Duration(minutes: 5)))) {
        continue;
      }
      allRows.add(r);
      (groups[date] ??= []).add(r);
    }
    ActivityTotals totals(Iterable<SavedRoute> rows) {
      final list = rows.toList();
      final physical = list.where((r) => r.activityType.name != 'driving');
      return ActivityTotals(
        rides: list.length,
        km: list.fold(0, (s, r) => s + r.distanceKm),
        seconds: list.fold(0, (s, r) => s + (r.durationMin * 60).round()),
        climb: list.fold(0, (s, r) => s + r.elevationGainMeters),
        physicalKm: physical.fold(0, (s, r) => s + r.distanceKm),
        physicalSeconds: physical.fold(
          0,
          (s, r) => s + (r.durationMin * 60).round(),
        ),
      );
    }

    final qualified = groups.entries
        .where((e) {
          final t = totals(e.value);
          return t.physicalKm >= 1 || t.physicalSeconds >= 600;
        })
        .map((e) => e.key)
        .toSet();
    final days = qualified.toList()..sort();
    var best = 0, chain = 0;
    DateTime? previous;
    for (final day in days) {
      chain = previous != null && day.difference(previous).inDays == 1
          ? chain + 1
          : 1;
      if (chain > best) best = chain;
      previous = day;
    }
    var cursor = qualified.contains(todayKey)
            ? todayKey
            : todayKey.subtract(const Duration(days: 1)),
        streak = 0;
    while (qualified.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return ActivitySummary(
      day: DateTime(clock.year, clock.month, clock.day),
      streak: streak,
      best: best,
      activeToday: qualified.contains(todayKey),
      activeDays: days.length,
      today: totals(groups[todayKey] ?? []),
      total: totals(allRows),
      week: List.generate(
        7,
        (i) => qualified.contains(todayKey.subtract(Duration(days: 6 - i))),
      ),
    );
  }
}

class ActivityService {
  Future<void> configure({bool? visible}) async {
    final client = Supabase.instance.client;
    if (client.auth.currentUser == null) return;
    await client
        .rpc(
          'configure_activity',
          params: {
            'p_offset_minutes': DateTime.now().timeZoneOffset.inMinutes,
            'p_visible': visible,
          },
        )
        .timeout(const Duration(seconds: 8));
  }

  Future<ActivitySummary> load(String userId) async {
    final client = Supabase.instance.client;
    final viewer = client.auth.currentUser?.id;
    final cache = AccountProgressCache(
      'activity',
      viewer == userId ? viewer : null,
    );
    try {
      if (viewer == userId) {
        try {
          await configure();
        } catch (_) {
          /* Still attempt the read. */
        }
      }
      final result = await client
          .rpc('get_profile_activity', params: {'p_user_id': userId})
          .timeout(const Duration(seconds: 10));
      if (client.auth.currentUser?.id != viewer)
        throw StateError('Account changed');
      await cache.write(result);
      return ActivitySummary.fromJson(Map<String, dynamic>.from(result as Map));
    } catch (_) {
      final saved = await cache.read();
      if (saved is! Map) rethrow;
      return ActivitySummary.fromJson(Map<String, dynamic>.from(saved));
    }
  }
}
