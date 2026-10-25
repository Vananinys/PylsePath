import '../models/saved_route.dart';
import 'achievements_service.dart';
import 'cycling_power.dart';

enum MedalRarity {
  bronze('Бронза', 25),
  silver('Серебро', 60),
  gold('Золото', 120),
  epic('Эпическая', 200),
  legendary('Легендарная', 350);

  const MedalRarity(this.label, this.xp);
  final String label;
  final int xp;
}

class JourneyRank {
  const JourneyRank(this.name, this.icon, this.xp, this.description);
  final String name, icon, description;
  final int xp;
  static const all = [
    JourneyRank(
      'На старте',
      '🌱',
      0,
      'Каждый большой путь начинается с первого заезда',
    ),
    JourneyRank(
      'Дорожный новичок',
      '🚲',
      60,
      'Первые медали уже ваши. Вы осваиваетесь и выбираете свой ритм.',
    ),
    JourneyRank(
      'Искатель маршрутов',
      '🧭',
      100,
      'Первые открытия уже позади. Впереди — новые дороги',
    ),
    JourneyRank(
      'Следопыт',
      '🧭',
      220,
      'Вы уже оставили немало следов на карте. Впереди новые маршруты.',
    ),
    JourneyRank(
      'В своём ритме',
      '🌊',
      350,
      'Движение становится частью вашей жизни',
    ),
    JourneyRank(
      'Страж дистанции',
      '🛡️',
      600,
      'Постоянство превращает каждый пройденный километр в большую историю.',
    ),
    JourneyRank(
      'Покоритель горизонтов',
      '🌄',
      850,
      'Дистанции растут вместе с вашей уверенностью',
    ),
    JourneyRank(
      'Хранитель ритма',
      '🌿',
      1250,
      'Вы нашли свой темп и возвращаетесь к движению снова и снова.',
    ),
    JourneyRank(
      'Мастер пути',
      '💎',
      1700,
      'Опыт, выносливость и привычка идти дальше',
    ),
    JourneyRank(
      'Мастер горизонта',
      '🌅',
      2300,
      'Опыт открывает новые расстояния. Следующая большая цель уже близко.',
    ),
    JourneyRank(
      'Легенда PulsePath',
      '👑',
      3000,
      'Большая коллекция маленьких побед',
    ),
    JourneyRank(
      'Покоритель вершин',
      '🏔️',
      4200,
      'Медали складываются в путь, которым можно гордиться.',
    ),
    JourneyRank(
      'Миф дорог',
      '🌠',
      5500,
      'Редкий титул для тех, чьи тренировки стали целой историей.',
    ),
  ];
}

class JourneyMedal {
  const JourneyMedal({
    required this.id,
    required this.badge,
    required this.category,
    required this.current,
    required this.target,
    required this.unit,
    required this.rarity,
    this.liveEligible = false,
  });
  final String id, category, unit;
  final Achievement badge;
  final double current, target;
  final MedalRarity rarity;
  final bool liveEligible;
  bool get earned => badge.earned;
  double get progress => earned
      ? 1
      : target <= 0
      ? 0
      : (current / target).clamp(0, 1);
  String get progressText => earned
      ? 'Получено · +${rarity.xp} XP'
      : '${_number(current.clamp(0, target))} / ${_number(target)}${unit.isEmpty ? '' : ' $unit'}';
  String get remainingText => earned
      ? 'В вашей коллекции'
      : 'Осталось ${_number((target - current).clamp(0, double.infinity))}${unit.isEmpty ? '' : ' $unit'}';
  String get story => switch (category) {
    'Дистанция' =>
      earned ? 'Крутой результат! Каждый маршрут стал частью большого пути.' : 'Большой путь складывается из небольших тренировок. Любая дистанция приближает эту медаль.',
    'Приключения' =>
      earned
          ? 'Впечатляющая дистанция за один старт! Эта медаль хранит память о вашем приключении.'
          : 'Один маршрут, одна большая цель. Двигайтесь в своём темпе и сохраняйте тренировку.',
    'Шаги' => earned ? 'Шаг за шагом — и вот новый рубеж. Отличная работа!' : 'Ваша прогулка тоже тренировка. Считайте шаги, сохраняйте занятия и собирайте свой путь.',
    'Регулярность' =>
      earned
          ? 'Вы находите время для движения. Именно так рождается привычка.'
          : 'Не обязательно двигаться быстро или далеко. Возвращайтесь к тренировкам, когда готовы.',
    'Вершины' =>
      earned
          ? 'Каждый подъём потребовал усилий. Теперь они сложились в новую вершину!'
          : 'Подъёмы складываются в общий результат. Высоту определяем по записанным GPS-данным.',
    'Выносливость' =>
      earned
          ? 'Вы подарили себе время в движении. Достойный повод гордиться собой.'
          : 'Важен ваш ритм. В копилку попадает время движения сохранённых тренировок.',
    'Открытия' =>
      earned
          ? 'Новый вид движения — новый взгляд на привычный путь. Продолжайте пробовать!'
          : 'Чередуйте прогулки, пробежки и велосипед. Для открытий не нужна гонка на скорость.',
    _ =>
      earned ? 'Крутой результат! Ещё одна история в вашей коллекции побед.' : 'Новая цель для вашей коллекции. Условия ниже помогут выбрать следующий шаг.',
  };
  static String _number(num value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}

/// Presentation and progress wrap existing award identities. No earned badge is renamed.
class AchievementJourney {
  AchievementJourney(this.rides, {DateTime? now}) {
    final reference = (now ?? DateTime.now()).toLocal();
    final today = DateTime(reference.year, reference.month, reference.day);
    final monday = DateTime(
      today.year,
      today.month,
      today.day - today.weekday + 1,
    );
    final nextMonday = DateTime(monday.year, monday.month, monday.day + 7);
    final week = rides.where((ride) {
      final at = ride.recordedDateTime?.toLocal();
      return at != null &&
          !at.isBefore(monday) &&
          at.isBefore(nextMonday) &&
          !at.isAfter(reference) &&
          ride.activityType.orsProfile != 'driving-car' &&
          (ride.distanceKm > 0 || ride.durationMin >= 1);
    }).toList();
    weeklyStart = monday;
    weeklyEnd = DateTime(nextMonday.year, nextMonday.month, nextMonday.day - 1);
    weeklyGoals = [
      JourneyWeeklyGoal(
        'Три старта',
        'Сохраните 3 тренировки на этой неделе.',
        week.length.toDouble(),
        3,
        'тренировки',
        '🚩',
      ),
      JourneyWeeklyGoal(
        'Час для себя',
        'Накопите 60 минут движения за неделю. Паузы не входят.',
        week.fold(0.0, (sum, ride) => sum + ride.durationMin),
        60,
        'мин',
        '⏳',
      ),
      JourneyWeeklyGoal(
        'Ритм недели',
        'Двигайтесь в 3 разных дня. Длительность и скорость выбираете вы.',
        week
            .map((ride) {
              final d = ride.recordedDateTime!.toLocal();
              return DateTime(d.year, d.month, d.day);
            })
            .toSet()
            .length
            .toDouble(),
        3,
        'дня',
        '🌿',
      ),
    ];
    final steps = rides.fold<int>(
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
    final total = AchievementsService.totalDistanceKm(rides);
    final longest = AchievementsService.longestRide(rides)?.distanceKm ?? 0;
    final minutes = rides.fold(0.0, (s, r) => s + r.durationMin);
    final climb = rides.fold(0.0, (s, r) => s + r.elevationGainMeters);
    final days = AchievementsService.activeDays(rides).toDouble();
    final streak = AchievementsService.weeklyStreak(rides, now: now).toDouble();
    var bestMinute = 0.0, bestFive = 0.0;
    for (final ride in rides.where(
      (r) =>
          r.workoutDetails.powerModel?['version'] == 1 &&
          !r.activityType.isFoot,
    )) {
      final power = PowerSummary.of(ride.workoutDetails);
      final minute = power.bestAverage(60) ?? 0;
      final five = power.bestAverage(300) ?? 0;
      if (minute > bestMinute) bestMinute = minute;
      if (five > bestFive) bestFive = five;
    }
    medals = AchievementsService.badges(rides, now: now)
        .map((badge) {
          final catalog = AchievementsService.catalog
              .where((c) => 'catalog:${c.row['id']}' == badge.id)
              .firstOrNull;
          var category = 'Особые', unit = '';
          var current = badge.earned ? badge.threshold.toDouble() : 0.0;
          final target = badge.threshold.toDouble();
          var live = false;
          final metric = catalog?.row['metric'];
          if (badge.title.endsWith('шагов в тренировках')) {
            category = 'Шаги';
            unit = 'шагов';
            current = steps.toDouble();
          } else if (badge.title == 'Два ритма' ||
              badge.title == 'Три стихии') {
            category = 'Открытия';
            unit = 'направления';
            current = disciplines.toDouble();
          } else if (metric == 'total_km' ||
              badge.publicDescription.startsWith('Суммарно') &&
                  badge.publicDescription.contains('км')) {
            category = 'Дистанция';
            unit = 'км';
            current = total;
            live = true;
          } else if (metric == 'longest_km' ||
              badge.publicDescription.startsWith('Один заезд')) {
            category = 'Приключения';
            unit = 'км';
            current = longest;
            live = true;
          } else if (metric == 'minutes' ||
              badge.title.contains('ч движения')) {
            category = 'Выносливость';
            unit = metric == 'minutes' ? 'мин' : 'ч';
            current = metric == 'minutes' ? minutes : minutes / 60;
            live = true;
          } else if (badge.title == 'Два часа за тренировку') {
            category = 'Выносливость';
            unit = 'мин';
            current = rides.fold(
              0.0,
              (s, r) => r.durationMin > s ? r.durationMin : s,
            );
            live = true;
          } else if (metric == 'climb_m' ||
              badge.publicDescription.contains('набора') ||
              badge.publicDescription.contains('набор')) {
            category = 'Вершины';
            unit = 'м';
            current = climb;
            live = true;
          } else if (metric == 'active_days' ||
              badge.title.contains('активных дней')) {
            category = 'Регулярность';
            unit = 'дн.';
            current = days;
          } else if (badge.publicDescription.contains('недели подряд')) {
            category = 'Регулярность';
            unit = 'нед.';
            current = streak;
          } else if (metric == 'rides' ||
              RegExp(r'^\d+ заездов$').hasMatch(badge.publicDescription) ||
              badge.title == 'Первый заезд') {
            category = 'Регулярность';
            unit = 'заездов';
            current = rides.length.toDouble();
          } else if (badge.title.contains('Вт') ||
              badge.title.contains('оценка') ||
              badge.title.contains('без пауз')) {
            category = 'Мастерство';
            live = true;
            if (badge.title.contains('Вт')) {
              current = bestMinute;
              unit = 'Вт ≈';
            } else if (badge.title == 'Пять минут усилия · оценка') {
              current = bestFive;
              unit = 'Вт ≈';
            }
          }
          // Preserve the XP of existing granted builtins while improving their category.
          final normalized =
              catalog == null &&
                  badge.description.startsWith('Выдано владельцем.')
              ? target
              : switch (category) {
                  'Шаги' => target / 1000,
                  'Открытия' => target * 5,
                  'Дистанция' => target / 10,
                  'Приключения' => target / 2,
                  'Вершины' => target / 100,
                  'Мастерство' => target / 10,
                  'Выносливость' => unit == 'ч' ? target * 2 : target / 15,
                  _ => target,
                };
          final rarity = normalized >= 100
              ? MedalRarity.legendary
              : normalized >= 40
              ? MedalRarity.epic
              : normalized >= 15
              ? MedalRarity.gold
              : normalized >= 5
              ? MedalRarity.silver
              : MedalRarity.bronze;
          return JourneyMedal(
            id:
                badge.id ??
                (catalog == null
                    ? 'builtin:${badge.title}'
                    : 'catalog:${catalog.row['id']}'),
            badge: badge,
            category: category,
            current: current,
            target: target,
            unit: unit,
            rarity: rarity,
            liveEligible: live && metric != 'manual',
          );
        })
        .toList(growable: false);
  }
  final List<SavedRoute> rides;
  late final List<JourneyMedal> medals;
  late final List<JourneyWeeklyGoal> weeklyGoals;
  late final DateTime weeklyStart, weeklyEnd;
  int get xp =>
      medals.where((m) => m.earned).fold(0, (s, m) => s + m.rarity.xp);
  JourneyRank get rank => JourneyRank.all.lastWhere((r) => xp >= r.xp);
  JourneyRank? get nextRank =>
      JourneyRank.all.where((r) => r.xp > xp).firstOrNull;
  double get rankProgress => nextRank == null
      ? 1
      : ((xp - rank.xp) / (nextRank!.xp - rank.xp)).clamp(0, 1);
  List<JourneyMedal> get nextGoals =>
      medals.where((m) => !m.earned && m.category != 'Особые').toList()
        ..sort((a, b) {
          final comparison = b.progress.compareTo(a.progress);
          return comparison == 0 ? a.target.compareTo(b.target) : comparison;
        });
}

class JourneyWeeklyGoal {
  const JourneyWeeklyGoal(
    this.title,
    this.description,
    this.current,
    this.target,
    this.unit,
    this.icon,
  );
  final String title, description, unit, icon;
  final double current, target;
  bool get completed => current >= target;
  double get progress => (current / target).clamp(0.0, 1.0);
  String get progressText =>
      '${current.clamp(0, target).floor()} / ${target.floor()} $unit';
}

class LiveAchievementSession {
  LiveAchievementSession(this.previous)
    : _seen = AchievementJourney(previous).medals
          .where((m) => m.earned)
          .map((m) => m.id)
          .toSet();
  final List<SavedRoute> previous;
  final Set<String> _seen;
  void remember(Iterable<String> ids) => _seen.addAll(ids);
  List<String> get announcedIds => List.unmodifiable(_seen);
  List<JourneyMedal> check(SavedRoute current, {bool completed = false}) {
    final journey = AchievementJourney([
      ...previous.where((r) => r.localId != current.localId),
      current,
    ]);
    final newly = journey.medals
        .where(
          (m) =>
              m.earned &&
              (completed || m.liveEligible) &&
              !_seen.contains(m.id),
        )
        .toList();
    _seen.addAll(newly.map((m) => m.id));
    return newly;
  }
}
