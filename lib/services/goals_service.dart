import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../models/progress_period.dart';

/// Ошибка сервиса целей с готовым для UI текстом.
class GoalsServiceException implements Exception {
  const GoalsServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Цели по периодам из таблицы `goals` и прогресс по ним из `rides`.
///
/// Колонки `goals`: id, user_id, period (day|week|month|year), goal_km,
/// updated_at. Значение `period` — это [ProgressPeriod.name].
///
/// Прогресс считается как сумма `distance_km` заездов текущего пользователя,
/// попавших в текущее окно периода (см. [ProgressPeriod.windowStart]).
class GoalsService {
  static const String _goalColumns = 'id, user_id, period, goal_km, updated_at';

  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  static bool get isAvailable => _client != null;

  String? get userId => _client?.auth.currentUser?.id;

  /// Строка для UPSERT цели. Публичная и чистая — проверяется тестами.
  static Map<String, dynamic> buildGoalRow({
    required String userId,
    required ProgressPeriod period,
    required double goalKm,
    DateTime? now,
  }) {
    return <String, dynamic>{
      'user_id': userId,
      'period': period.name,
      'goal_km': _sanitize(goalKm, period),
      // The deployed schema retains these required legacy columns as well.
      'period_type': period.name,
      'target_distance_km': _sanitize(goalKm, period),
      'updated_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
    };
  }

  /// Значение `period` из строки БД → [ProgressPeriod].
  static ProgressPeriod periodFromDb(Object? value) {
    final name = value?.toString();
    return ProgressPeriod.values.firstWhere(
      (period) => period.name == name,
      orElse: () => ProgressPeriod.month,
    );
  }

  /// Цели пользователя, фактически записанные в `goals`.
  ///
  /// Возвращаются только периоды, для которых в БД есть строка — так
  /// вызывающий код отличает «в облаке цели нет» (использовать локальное
  /// значение) от «в облаке цель равна дефолту».
  Future<Map<ProgressPeriod, double>> fetchGoals({bool strict = false}) async {
    final result = <ProgressPeriod, double>{};

    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) {
      if (strict) throw const GoalsServiceException('Нет сессии');
      return result;
    }

    try {
      final rows = await client
          .from(AppConfig.goalsTable)
          .select(_goalColumns)
          .eq('user_id', id)
          .timeout(const Duration(seconds: 12));
      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw);
        final period = periodFromDb(row['period']);
        final goal = _toDouble(row['goal_km']);
        if (goal != null) {
          result[period] = _sanitize(goal, period);
        }
      }
    } on PostgrestException catch (error) {
      debugPrint('[GoalsService] fetch ${error.code}: ${error.message}');
      if (strict) rethrow;
    } catch (error) {
      debugPrint('[GoalsService] fetch failed: $error');
      if (strict) rethrow;
    }
    return result;
  }

  /// Цель для одного периода (из облака, иначе дефолт периода).
  Future<double> goalFor(ProgressPeriod period) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return period.defaultGoalKm;

    try {
      final row = await client
          .from(AppConfig.goalsTable)
          .select('goal_km')
          .eq('user_id', id)
          .eq('period', period.name)
          .maybeSingle()
          .timeout(const Duration(seconds: 12));
      if (row == null) return period.defaultGoalKm;
      final goal = _toDouble(row['goal_km']);
      return goal == null ? period.defaultGoalKm : _sanitize(goal, period);
    } on PostgrestException catch (error) {
      debugPrint('[GoalsService] goalFor ${error.code}: ${error.message}');
      return period.defaultGoalKm;
    } catch (error) {
      debugPrint('[GoalsService] goalFor failed: $error');
      return period.defaultGoalKm;
    }
  }

  /// Устанавливает цель периода (UPSERT по ключу user_id + period).
  Future<bool> setGoal(ProgressPeriod period, double goalKm) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) {
      debugPrint('[GoalsService] нет сессии — цель не сохранена в облако');
      return false;
    }

    try {
      await client
          .from(AppConfig.goalsTable)
          .upsert(
            buildGoalRow(userId: id, period: period, goalKm: goalKm),
            onConflict: 'user_id,period',
          )
          .timeout(const Duration(seconds: 15));
      debugPrint('[GoalsService] цель ${period.name} сохранена');
      return true;
    } on PostgrestException catch (error) {
      debugPrint('[GoalsService] setGoal ${error.code}: ${error.message}');
      return false;
    } catch (error) {
      debugPrint('[GoalsService] setGoal failed: $error');
      return false;
    }
  }

  /// Прогресс (сумма км) за текущее окно периода по записям `rides`.
  Future<double> progressFor(ProgressPeriod period) async {
    final now = DateTime.now();
    return totalDistanceSince(period.windowStart(now));
  }

  /// Прогресс по всем периодам (день/неделя/месяц/год) одним нагруженным
  /// запросом: берём все заезды за самое широкое окно (год) и суммируем локально.
  Future<Map<ProgressPeriod, double>> progressForAll() async {
    final now = DateTime.now();
    final yearStart = ProgressPeriod.year
        .windowStart(now)
        .toUtc()
        .toIso8601String();

    final progress = <ProgressPeriod, double>{
      for (final period in ProgressPeriod.values) period: 0,
    };

    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return progress;

    try {
      final rows = await client
          .from(AppConfig.ridesTable)
          .select('distance_km, created_at')
          .eq('user_id', id)
          .gte('created_at', yearStart)
          .timeout(const Duration(seconds: 15));

      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw);
        final distance = _toDouble(row['distance_km']) ?? 0;
        final createdAt = _parseDate(row['created_at']);
        if (createdAt == null) continue;
        for (final period in ProgressPeriod.values) {
          if (period.contains(createdAt.toLocal(), now)) {
            progress[period] = (progress[period] ?? 0) + distance;
          }
        }
      }
    } on PostgrestException catch (error) {
      debugPrint('[GoalsService] progressAll ${error.code}: ${error.message}');
    } catch (error) {
      debugPrint('[GoalsService] progressAll failed: $error');
    }
    return progress;
  }

  /// Сумма `distance_km` заездов, созданных после [since].
  Future<double> totalDistanceSince(DateTime since) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return 0;

    try {
      final rows = await client
          .from(AppConfig.ridesTable)
          .select('distance_km')
          .eq('user_id', id)
          .gte('created_at', since.toUtc().toIso8601String())
          .timeout(const Duration(seconds: 15));

      var total = 0.0;
      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw);
        total += _toDouble(row['distance_km']) ?? 0;
      }
      return total;
    } on PostgrestException catch (error) {
      debugPrint('[GoalsService] totalSince ${error.code}: ${error.message}');
      return 0;
    } catch (error) {
      debugPrint('[GoalsService] totalSince failed: $error');
      return 0;
    }
  }

  /// Приводит цель к допустимому диапазону; NaN → дефолт периода.
  static double _sanitize(double value, ProgressPeriod period) {
    if (!value.isFinite) return period.defaultGoalKm;
    return value
        .clamp(ProgressPeriod.minGoalKm, ProgressPeriod.maxGoalKm)
        .toDouble();
  }

  static double? _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static DateTime? _parseDate(Object? value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}
