import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/progress_period.dart';
import 'user_scope.dart';
import '../services/goals_service.dart';

/// Хранилище целей прогресса: своя цель для каждого периода
/// (день/неделя/месяц/год) + запоминание последнего выбранного периода.
///
/// Offline changes are persisted with a pending marker, take precedence
/// over an older cloud value, and retry when the repository next loads.
class ProgressGoalsRepository {
  final GoalsService _goalsService = GoalsService();
  final String? _owner = UserScope.currentUserId();
  String _key(String base) => UserScope.keyFor(base, _owner);
  String _dirtyKey(ProgressPeriod p) => _key('progress_goal_pending_${p.name}');
  bool get _current => UserScope.currentUserId() == _owner;

  final Map<ProgressPeriod, double> _goals = {
    for (final period in ProgressPeriod.values) period: period.defaultGoalKm,
  };

  ProgressPeriod _period = ProgressPeriod.month;

  /// Цели из облака уже подтянуты в этой сессии.
  bool _cloudPulled = false;

  /// Выбранный пользователем период (по умолчанию — месяц).
  ProgressPeriod get period => _period;

  /// Цель для периода в километрах.
  double goalFor(ProgressPeriod period) =>
      _goals[period] ?? period.defaultGoalKm;

  /// Приводит цель к допустимым границам.
  /// `clamp` не отсекает NaN (Dart считает NaN больше любого числа),
  /// поэтому нечисловые значения заменяем на дефолт периода.
  static double _sanitize(double value, ProgressPeriod period) {
    if (!value.isFinite) return period.defaultGoalKm;
    return value
        .clamp(ProgressPeriod.minGoalKm, ProgressPeriod.maxGoalKm)
        .toDouble();
  }

  Future<void> load({bool syncCloud = true}) async {
    if (!_current) return;
    try {
      final prefs = await SharedPreferences.getInstance();

      for (final period in ProgressPeriod.values) {
        // Цели — пер-аккаунтово (UserScope), как и профиль.
        final scopedKey = _key(period.storageKey);
        final stored = prefs.getDouble(scopedKey);
        if (stored != null) {
          _goals[period] = _sanitize(stored, period);
        }
      }

      final storedPeriod = prefs.getString(
        _key(ProgressPeriod.selectedPeriodKey),
      );
      _period = ProgressPeriod.values.firstWhere(
        (period) => period.name == storedPeriod,
        orElse: () => ProgressPeriod.month,
      );
    } catch (_) {
      // Нет доступа к хранилищу — остаются значения по умолчанию.
    }

    // Облако тянем один раз за сессию: значения из `goals` перекрывают
    // локальный кэш (там цели могли поменяться с другого устройства).
    if (syncCloud && _current && _owner != null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        if (!_cloudPulled) {
          final remote = await _goalsService
              .fetchGoals(strict: true)
              .timeout(const Duration(seconds: 10));
          if (!_current) return;
          for (final entry in remote.entries) {
            if (prefs.getBool(_dirtyKey(entry.key)) == true) continue;
            _goals[entry.key] = _sanitize(entry.value, entry.key);
            await prefs.setDouble(
              _key(entry.key.storageKey),
              _goals[entry.key]!,
            );
          }
          _cloudPulled = true;
          for (final period in ProgressPeriod.values) {
            if (!remote.containsKey(period) &&
                prefs.containsKey(_key(period.storageKey))) {
              await prefs.setBool(_dirtyKey(period), true);
            }
          }
        }
        for (final period in ProgressPeriod.values) {
          if (!_current) return;
          if (prefs.getBool(_dirtyKey(period)) != true) continue;
          final value = prefs.getDouble(_key(period.storageKey));
          if (value == null) continue;
          final sent = await _goalsService.setGoal(period, value);
          if (_current &&
              sent &&
              prefs.getDouble(_key(period.storageKey)) == value) {
            await prefs.remove(_dirtyKey(period));
          }
        }
      } catch (error) {
        debugPrint(
          '[ProgressGoals] не удалось подтянуть цели из облака: $error',
        );
      }
    }
  }

  /// Сохраняет цель для периода (значение обрезается по границам) и
  /// отправляет её в Supabase (best effort).
  Future<void> setGoal(ProgressPeriod period, double goalKm) async {
    if (!_current) throw StateError('Аккаунт изменился');
    final value = _sanitize(goalKm, period);
    final prefs = await SharedPreferences.getInstance();
    if (!_current) throw StateError('Аккаунт изменился');
    if (!await prefs.setBool(_dirtyKey(period), true) ||
        !await prefs.setDouble(_key(period.storageKey), value)) {
      throw StateError('Не удалось сохранить цель на устройстве');
    }
    _goals[period] = value;
    try {
      if (!_current || _owner == null) return;
      final sent = await _goalsService.setGoal(period, value);
      if (_current &&
          sent &&
          prefs.getDouble(_key(period.storageKey)) == value) {
        await prefs.remove(_dirtyKey(period));
      }
    } catch (error) {
      debugPrint('[ProgressGoals] цель не уехала в облако: $error');
    }
  }

  /// Запоминает выбранный период, чтобы он сохранялся между запусками.
  Future<void> setPeriod(ProgressPeriod period) async {
    if (!_current) return;
    _period = period;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key(ProgressPeriod.selectedPeriodKey),
        period.name,
      );
    } catch (_) {}
  }
}
