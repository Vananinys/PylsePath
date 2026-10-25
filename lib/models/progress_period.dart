/// Период, за который считается прогресс в профиле райдера.
///
/// Здесь же лежат границы цели и арифметика окон — чтобы UI и хранилище
/// пользовались одним источником правды (как [UserProfile] для веса/роста).
enum ProgressPeriod {
  day(
    label: 'День',
    blockTitle: 'Прогресс за день',
    metricLabel: 'Пробег за день',
    goalTitle: 'Цель на день',
    defaultGoalKm: 20,
    storageKey: 'progress_goal_day',
  ),
  week(
    label: 'Неделя',
    blockTitle: 'Прогресс за неделю',
    metricLabel: 'Пробег за неделю',
    goalTitle: 'Цель на неделю',
    defaultGoalKm: 100,
    storageKey: 'progress_goal_week',
  ),
  month(
    label: 'Месяц',
    blockTitle: 'Прогресс за месяц',
    metricLabel: 'Пробег за месяц',
    goalTitle: 'Цель на месяц',
    defaultGoalKm: 400,
    storageKey: 'progress_goal_month',
  ),
  year(
    label: 'Год',
    blockTitle: 'Прогресс за год',
    metricLabel: 'Пробег за год',
    goalTitle: 'Цель на год',
    defaultGoalKm: 4000,
    storageKey: 'progress_goal_year',
  );

  const ProgressPeriod({
    required this.label,
    required this.blockTitle,
    required this.metricLabel,
    required this.goalTitle,
    required this.defaultGoalKm,
    required this.storageKey,
  });

  /// Короткая подпись для переключателя периодов.
  final String label;

  /// Заголовок блока («Прогресс за неделю»).
  final String blockTitle;

  /// Подпись метрики («Пробег за неделю»).
  final String metricLabel;

  /// Заголовок диалога смены цели («Цель на неделю»).
  final String goalTitle;

  /// Цель по умолчанию, если пользователь ещё ничего не задавал.
  final double defaultGoalKm;

  /// Ключ в SharedPreferences: цель хранится отдельно для каждого периода.
  final String storageKey;

  /// Допустимые границы цели, км.
  static const double minGoalKm = 10;
  static const double maxGoalKm = 5000;

  /// Ключ хранения выбранного периода.
  static const String selectedPeriodKey = 'progress_period';

  /// Начало текущего окна периода в локальном времени.
  ///
  /// День — с полуночи, неделя — с понедельника, месяц — с 1-го числа,
  /// год — с 1 января. Конструктор `DateTime` сам нормализует выход за
  /// границы месяца (например, `DateTime(2026, 3, 0)` == 28 февраля), поэтому
  /// арифметика не ломается на стыках месяцев и не зависит от переходов
  /// на летнее время (в отличие от вычитания `Duration(days: ...)`).
  DateTime windowStart(DateTime now) {
    switch (this) {
      case ProgressPeriod.day:
        return DateTime(now.year, now.month, now.day);
      case ProgressPeriod.week:
        // DateTime.weekday: понедельник == 1.
        return DateTime(now.year, now.month, now.day - (now.weekday - 1));
      case ProgressPeriod.month:
        return DateTime(now.year, now.month);
      case ProgressPeriod.year:
        return DateTime(now.year);
    }
  }

  /// Попадает ли дата заезда [when] в текущий период.
  ///
  /// Границы включительно: заезд, сделанный ровно в полночь начала периода,
  /// считается. Даты «из будущего» (сбитые часы на устройстве) тоже
  /// попадают в период — иначе только что записанный заезд пропадал бы
  /// из статистики.
  bool contains(DateTime when, DateTime now) =>
      !when.isBefore(windowStart(now));
}
