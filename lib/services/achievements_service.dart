import '../models/saved_route.dart';
import '../models/owner_award.dart';
import '../data/user_scope.dart';
import '../data/progress_backup_repository.dart';
import '../data/account_progress_cache.dart';
import '../data/profile_appearance_store.dart';
import 'cycling_power.dart';
import 'personal_records.dart';

class CatalogAchievement {
  const CatalogAchievement(this.row);
  final Map<String, dynamic> row;
  static const metrics = {
    'total_km': 'Всего километров',
    'longest_km': 'Один заезд, км',
    'rides': 'Количество тренировок',
    'minutes': 'Всего минут',
    'active_days': 'Активных дней',
    'climb_m': 'Всего набора высоты, м',
    'manual': 'Вручную владельцем',
  };
  Achievement evaluate(List<SavedRoute> rides) {
    final value = switch (row['metric']) {
      'total_km' => AchievementsService.totalDistanceKm(rides),
      'longest_km' => AchievementsService.longestRide(rides)?.distanceKm ?? 0,
      'rides' => rides.length,
      'minutes' => rides.fold(0.0, (s, r) => s + r.durationMin),
      'active_days' => AchievementsService.activeDays(rides),
      'climb_m' => rides.fold(0.0, (s, r) => s + r.elevationGainMeters),
      _ => 0,
    };
    final threshold = (row['threshold'] as num).toDouble();
    final automatic = row['metric'] != 'manual' && value >= threshold;
    final serverEarned = AchievementsService.hasEarnedCatalog(
      row['id'] as String,
    );
    final granted = AchievementsService.hasGrantedCatalog(row['id'] as String);
    return Achievement(
      id: 'catalog:${row['id']}',
      icon: row['icon'] as String,
      title: row['title'] as String,
      description: granted && !automatic && !serverEarned
          ? 'Выдано владельцем. ${row['description']}'
          : row['description'] as String,
      threshold: threshold,
      earned: automatic || serverEarned || granted,
    );
  }
}

/// Личные рекорды и достижения, посчитанные из истории заездов.
///
/// Все вычисления — чистые статические функции: легко тестировать, данные —
/// [SavedRoute] из локальной истории (включая слитые облачные заезды).
/// Никаких новых колонок в БД не требуется.
class AchievementsService {
  static List<CatalogAchievement> catalog = const [];
  static List<OwnerAward> ownerIssued = const [];
  static String? _cacheUserId;
  static Set<String> _earnedCatalogKeys = {};
  static List<OwnerAward> _earnedReceipts = const [];
  static Set<String> _savedBuiltins = {};

  static void bindToUser(String? userId) {
    if (_cacheUserId == userId) return;
    _cacheUserId = userId;
    catalog = const [];
    ownerIssued = const [];
    _earnedCatalogKeys = {};
    _earnedReceipts = const [];
    _savedBuiltins = {};
  }

  static Future<void> restoreProgress() async {
    final owner = UserScope.currentUserId();
    bindToUser(owner);
    final state = await ProgressBackupRepository().read();
    if (UserScope.currentUserId() != owner) return;
    _savedBuiltins = (state['unlocked'] as Map? ?? {}).keys
        .cast<String>()
        .toSet();
    final cachedCatalog = await AccountProgressCache(
      'achievement_catalog',
      owner,
    ).read();
    final cachedAwards = await AccountProgressCache(
      'owner_awards',
      owner,
    ).read();
    final cachedPresentation = owner == null
        ? null
        : await ProfileAppearanceStore(owner).read();
    if (UserScope.currentUserId() != owner) return;
    if (cachedCatalog is List) {
      catalog = cachedCatalog
          .map((r) => CatalogAchievement(Map<String, dynamic>.from(r as Map)))
          .toList();
    }
    if (cachedAwards is List) {
      ownerIssued = cachedAwards
          .map((r) => OwnerAward.fromJson(Map<String, dynamic>.from(r as Map)))
          .toList();
    }
    if (cachedPresentation != null &&
        cachedPresentation['rewards'] is List &&
        owner != null) {
      final earned = (cachedPresentation['rewards'] as List).where(
        (r) => r['source'] == 'earned',
      );
      setEarnedCatalog(
        owner,
        earned.map((r) => r['award_key'] as String),
        receipts: earned
            .map(
              (r) => OwnerAward.fromJson(Map<String, dynamic>.from(r as Map)),
            )
            .toList(),
      );
    }
  }

  static Future<void> captureProgress(List<SavedRoute> rides) async {
    final owner = UserScope.currentUserId();
    bindToUser(owner);
    final earned = <String, dynamic>{};
    for (final badge in badges(rides)) {
      if (badge.id != null ||
          !badge.earned ||
          badge.description.startsWith('Выдано владельцем.'))
        continue;
      final key = 'builtin:${badge.title}';
      earned[key] = {
        'title': badge.title,
        'icon': badge.icon,
        'earnedAt': DateTime.now().toUtc().toIso8601String(),
      };
    }
    if (UserScope.currentUserId() != owner) return;
    await ProgressBackupRepository().update({'unlocked': earned});
    if (UserScope.currentUserId() == owner) _savedBuiltins.addAll(earned.keys);
  }

  static void setEarnedCatalog(
    String userId,
    Iterable<String> keys, {
    List<OwnerAward> receipts = const [],
  }) {
    if (UserScope.currentUserId() != userId) return;
    bindToUser(userId);
    _earnedCatalogKeys = keys.toSet();
    _earnedReceipts = List.unmodifiable(receipts);
  }

  static bool hasEarnedCatalog(String id) =>
      _cacheUserId == UserScope.currentUserId() &&
      _earnedCatalogKeys.contains('catalog:$id');

  static bool hasGrantedCatalog(String id) =>
      _cacheUserId == UserScope.currentUserId() &&
      ownerIssued.any((a) => a.kind == 'achievement' && a.key == 'catalog:$id');
  const AchievementsService._();

  /// Суммарная дистанция всех заездов, км.
  static double totalDistanceKm(List<SavedRoute> rides) =>
      rides.fold(0.0, (sum, ride) => sum + ride.distanceKm);

  /// Заезд с максимальной дистанцией (null — заездов нет).
  static SavedRoute? longestRide(List<SavedRoute> rides) {
    SavedRoute? best;
    for (final ride in rides) {
      if (best == null || ride.distanceKm > best.distanceKm) best = ride;
    }
    return best;
  }

  /// Заезд с максимальной средней скоростью (км/ч). Заезды без времени
  /// (0 мин) не участвуют.
  static SavedRoute? fastestRide(List<SavedRoute> rides) {
    SavedRoute? best;
    var bestSpeed = 0.0;
    for (final ride in rides) {
      final hours = ride.durationMin / 60.0;
      if (hours <= 0) continue;
      final speed = ride.distanceKm / hours;
      if (speed > bestSpeed) {
        bestSpeed = speed;
        best = ride;
      }
    }
    return best;
  }

  /// Средняя скорость конкретного заезда (км/ч).
  static double averageSpeedKmh(SavedRoute ride) {
    final hours = ride.durationMin / 60.0;
    if (hours <= 0) return 0;
    return ride.distanceKm / hours;
  }

  /// Заезд с максимальным набором высоты (0 у старых записей без высоты).
  static SavedRoute? biggestClimb(List<SavedRoute> rides) {
    SavedRoute? best;
    for (final ride in rides) {
      if (best == null || ride.elevationGainMeters > best.elevationGainMeters) {
        best = ride;
      }
    }
    if (best != null && best.elevationGainMeters <= 0) return null;
    return best;
  }

  /// Количество дней с хотя бы одним заездом.
  static int activeDays(List<SavedRoute> rides) =>
      rides.map((ride) => _dayKey(ride.dateTime.toLocal())).toSet().length;

  /// Серия недель подряд (пн–вс) с хотя бы одним заездом, считая назад от
  /// текущей недели. Неделя без заездов обрывает серию.
  static int weeklyStreak(List<SavedRoute> rides, {DateTime? now}) {
    if (rides.isEmpty) return 0;
    final reference = now ?? DateTime.now();

    DateTime weekStart(DateTime value) {
      final date = value.toLocal();
      final day = DateTime(date.year, date.month, date.day);
      return day.subtract(Duration(days: day.weekday - 1));
    }

    final weeks = rides
        .map((ride) => _dayKey(weekStart(ride.dateTime)))
        .toSet();
    final currentWeek = weekStart(reference);
    // Если в текущей неделе заездов ещё нет — серия начинается с прошлой.
    var week = weeks.contains(_dayKey(currentWeek))
        ? currentWeek
        : weekStart(currentWeek.subtract(const Duration(days: 1)));

    var streak = 0;
    while (weeks.contains(_dayKey(week))) {
      streak++;
      week = weekStart(week.subtract(const Duration(days: 1)));
    }
    return streak;
  }

  static String _dayKey(DateTime date) {
    final local = date.toLocal();
    return '${local.year}-${local.month}-${local.day}';
  }

  /// Достижения-бейджи: пороги по суммарному пробегу, количеству заездов,
  /// серии недель и суммарному набору высоты.
  static List<Achievement> badges(List<SavedRoute> rides, {DateTime? now}) {
    final totalKm = totalDistanceKm(rides);
    final totalClimb = rides.fold(
      0.0,
      (sum, ride) => sum + ride.elevationGainMeters,
    );
    final streak = weeklyStreak(rides, now: now);
    final count = rides.length;

    final minutes = rides.fold(0.0, (sum, ride) => sum + ride.durationMin);
    final longest = longestRide(rides)?.distanceKm ?? 0;
    final days = activeDays(rides);
    final powerRides = rides
        .where(
          (r) =>
              r.workoutDetails.powerModel?['version'] == 1 &&
              !r.activityType.isFoot,
        )
        .toList();
    var bestMinute = 0.0, bestFive = 0.0;
    for (final r in powerRides) {
      final p = PowerSummary.of(r.workoutDetails);
      final minute = p.bestAverage(60) ?? 0;
      final five = p.bestAverage(300) ?? 0;
      if (minute > bestMinute) bestMinute = minute;
      if (five > bestFive) bestFive = five;
    }
    final badges = <Achievement>[
      ...catalog.map((definition) => definition.evaluate(rides)),
      if (_cacheUserId == UserScope.currentUserId())
        ..._earnedReceipts
            .where(
              (award) =>
                  !catalog.any((c) => award.key == 'catalog:${c.row['id']}'),
            )
            .map(
              (award) => Achievement(
                id: award.key,
                icon: award.icon,
                title: award.label,
                description: 'Заработано тренировками',
                threshold: 1,
                earned: true,
              ),
            ),
      ...ownerIssued
          .where(
            (award) =>
                award.kind == 'achievement' &&
                !award.key.startsWith('builtin:') &&
                !_earnedCatalogKeys.contains(award.key) &&
                !catalog.any((c) => award.key == 'catalog:${c.row['id']}'),
          )
          .map(
            (award) => Achievement(
              id: award.key,
              icon: award.icon,
              title: award.label,
              description: 'Награда владельца приложения',
              threshold: 1,
              earned: true,
            ),
          ),
    ];
    final walkingSteps = rides.fold<int>(
      0,
      (sum, ride) =>
          sum +
          (ride.activityType.isFoot
              ? ride.workoutDetails.walkingSteps?.count ?? 0
              : 0),
    );
    final disciplines = rides
        .where(
          (ride) =>
              ride.activityType.orsProfile != 'driving-car' &&
              (ride.distanceKm > 0 || ride.durationMin >= 1),
        )
        .map(
          (ride) => ride.activityType.isFoot
              ? (ride.activityType.name.toLowerCase().contains('running')
                    ? 'running'
                    : 'walking')
              : 'cycling',
        )
        .toSet()
        .length;
    final builtins = <Achievement>[
      for (final steps in [1000, 5000, 10000, 50000, 100000])
        Achievement(
          icon: '👣',
          title: '$steps шагов в тренировках',
          description:
              'Сохраните пешие тренировки с суммарным результатом от $steps шагов. Учитываются шаги внутри тренировок, без пауз; дневной счётчик отдельно не прибавляется.',
          threshold: steps,
        ).isEarned(walkingSteps >= steps),
      for (final kinds in [2, 3])
        Achievement(
          icon: '🧩',
          title: kinds == 2 ? 'Два ритма' : 'Три стихии',
          description:
              'Попробуйте $kinds разных направления: ходьба, бег и велосипед. Сохраните в каждом тренировку с дистанцией или хотя бы минутой движения.',
          threshold: kinds,
        ).isEarned(disciplines >= kinds),

      for (final watts in [100, 150, 200, 250, 300])
        Achievement(
          icon: '⚡',
          title: 'Расчётные $watts Вт · минута',
          description:
              'Средняя GPS-оценка за непрерывную минуту ≥ $watts Вт. Не измеритель мощности.',
          threshold: watts,
        ).isEarned(bestMinute >= watts),
      const Achievement(
        icon: '🔋',
        title: 'Пять минут усилия · оценка',
        description:
            'Расчётная мощность ≥ 150 Вт за 5 минут без пауз и пропусков GPS',
        threshold: 150,
      ).isEarned(bestFive >= 150),
      for (final km in [5, 10])
        Achievement(
          icon: '🏆',
          title: '$km км без пауз',
          description: 'Непрерывный отрезок с GPS-данными на $km км',
          threshold: km,
        ).isEarned(
          rides.any(
            (r) =>
                PersonalRecords.fastestDistance(r.workoutDetails, km * 1000) !=
                null,
          ),
        ),
      const Achievement(
        icon: '⏳',
        title: 'Два часа за тренировку',
        description: '120 минут движения в одной тренировке',
        threshold: 120,
      ).isEarned(rides.any((r) => r.durationMin >= 120)),
      for (final entry in [
        (3, 'Набираю темп'),
        (5, 'В привычке'),
        (50, 'Полсотни стартов'),
        (100, 'Сотня стартов'),
      ])
        Achievement(
          icon: '🏅',
          title: entry.$2,
          description: '${entry.$1} заездов',
          threshold: entry.$1,
        ).isEarned(count >= entry.$1),
      for (final km in [5, 10, 25, 500, 1000, 2500])
        Achievement(
          icon: '🗺️',
          title: '$km км пути',
          description: 'Суммарно $km км',
          threshold: km,
        ).isEarned(totalKm >= km),
      for (final km in [5, 10, 25, 50, 100])
        Achievement(
          icon: '🚩',
          title: '$km км за раз',
          description: 'Один заезд от $km км',
          threshold: km,
        ).isEarned(longest >= km),
      for (final day in [3, 7, 30, 100])
        Achievement(
          icon: '📅',
          title: '$day активных дней',
          description: 'Заезды в $day разных дней',
          threshold: day,
        ).isEarned(days >= day),
      for (final hours in [1, 5, 10, 50])
        Achievement(
          icon: '⏱️',
          title: '$hours ч движения',
          description: 'Суммарно $hours ч',
          threshold: hours,
        ).isEarned(minutes >= hours * 60),
      for (final climb in [100, 500, 1000, 5000])
        Achievement(
          icon: '🏔️',
          title: '$climb м вверх',
          description: 'Суммарный набор $climb м',
          threshold: climb,
        ).isEarned(totalClimb >= climb),
      const Achievement(
        icon: '🚲',
        title: 'Первый заезд',
        description: 'Завершить первый заезд',
        threshold: 1,
      ).isEarned(count >= 1),
      const Achievement(
        icon: '🚴',
        title: 'Десятка',
        description: '10 заездов',
        threshold: 10,
      ).isEarned(count >= 10),
      const Achievement(
        icon: '🏍️',
        title: 'Ветеран',
        description: '25 заездов',
        threshold: 25,
      ).isEarned(count >= 25),
      const Achievement(
        icon: '🛣️',
        title: '50 км',
        description: 'Суммарно 50 км',
        threshold: 50,
      ).isEarned(totalKm >= 50),
      const Achievement(
        icon: '💯',
        title: 'Сотня',
        description: 'Суммарно 100 км',
        threshold: 100,
      ).isEarned(totalKm >= 100),
      const Achievement(
        icon: '🌟',
        title: '250 км',
        description: 'Суммарно 250 км',
        threshold: 250,
      ).isEarned(totalKm >= 250),
      const Achievement(
        icon: '🔥',
        title: 'Две недели',
        description: 'Заезды 2 недели подряд',
        threshold: 2,
      ).isEarned(streak >= 2),
      const Achievement(
        icon: '⚡',
        title: 'Месяц огня',
        description: 'Заезды 4 недели подряд',
        threshold: 4,
      ).isEarned(streak >= 4),
      const Achievement(
        icon: '⛰️',
        title: 'Горист',
        description: '2000 м набора высоты суммарно',
        threshold: 2000,
      ).isEarned(totalClimb >= 2000),
    ];
    return [
      ...badges,
      ...builtins.map((badge) {
        if (_cacheUserId == UserScope.currentUserId() &&
            _savedBuiltins.contains('builtin:${badge.title}')) {
          return badge.isEarned(true);
        }
        final issued = ownerIssued
            .where(
              (award) =>
                  award.kind == 'achievement' &&
                  award.key == 'builtin:${badge.title}',
            )
            .firstOrNull;
        if (issued == null || badge.earned) return badge;
        return Achievement(
          id: badge.id,
          icon: badge.icon,
          title: badge.title,
          description: 'Выдано владельцем. ${badge.description}',
          threshold: badge.threshold,
          earned: true,
        );
      }),
    ];
  }
}

/// Один бейдж достижения. [threshold] — условное значение для прогресса,
/// [earned] — получено ли.
class Achievement {
  final String? id;
  final String icon;
  final String title;
  final String description;
  final num threshold;
  final bool earned;

  const Achievement({
    this.id,
    required this.icon,
    required this.title,
    required this.description,
    required this.threshold,
    this.earned = false,
  });

  /// Public copy is independent of internal grant/progress metadata.
  String get publicDescription {
    final clean = description
        .replaceAll(
          RegExp(
            r'^(Выдано владельцем\.?\s*|Награда владельца приложения\.?\s*)',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return clean.isEmpty ? 'Особая награда в вашей коллекции.' : clean;
  }

  Achievement isEarned(bool value) => Achievement(
    id: id,
    icon: icon,
    title: title,
    description: description,
    threshold: threshold,
    earned: value,
  );
}
