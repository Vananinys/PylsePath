import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/user_scope.dart';

/// Fixed vocabulary only: callers cannot submit coordinates, text or IDs.
enum UsageEvent {
  appOpened('Открытие приложения'),
  savedRoutesOpened('Сохранённые маршруты'),
  chatsOpened('Открытие чатов'),
  communityOpened('Открытие сообщества'),
  trainingOpened('Тренировочный центр'),
  achievementsOpened('Достижения'),
  heatmapOpened('Тепловая карта'),
  offlineMapsOpened('Офлайн-карты'),
  groupOpened('Совместная поездка'),
  garageOpened('Гараж'),
  workoutStarted('Начата тренировка'),
  workoutPaused('Ручная пауза'),
  workoutResumed('Продолжена тренировка'),
  workoutSaved('Тренировка сохранена'),
  workoutSaveFailed('Ошибка сохранения тренировки'),
  workoutDiscarded('Тренировка отменена'),
  routeBuilt('Маршрут построен'),
  routeBuildFailed('Ошибка построения маршрута'),
  gpsStreamFailed('Ошибка потока GPS'),
  gpsRecoveryStarted('Повторное подключение GPS'),
  gpsRecovered('GPS восстановлен');

  const UsageEvent(this.label);
  final String label;
}

/// Local, voluntary counters. This class has no network client or upload path.
class UsageStatistics {
  UsageStatistics({
    String? Function()? ownerResolver,
    DateTime Function()? clock,
  }) : _ownerResolver = ownerResolver ?? UserScope.currentUserId,
       _clock = clock ?? DateTime.now;
  static final instance = UsageStatistics();
  static const consentVersion = 'local-counters-2026-10-28.1';
  static const consentText =
      'Я разрешаю PulsePath вести на этом устройстве счётчики использования функций и технических результатов записи для улучшения приложения. '
      'Сохраняются день, версия приложения, название события из фиксированного списка и число срабатываний. '
      'Координаты, маршруты, названия мест, сообщения, фото, e-mail и идентификатор аккаунта в отчёт не входят. '
      'Счётчики хранятся до 30 дней. Автоматической отправки нет. Передать отчёт оператору Сараеву Сергею (ss9058766@gmail.com) можно только отдельным действием после просмотра. '
      'Выбор необязателен, на работу функций не влияет. Можно выключить счётчики и очистить их в этом разделе. '
      'Ручная передача через выбранное приложение может раскрыть получателю сведения отправителя; его условия действуют отдельно.';
  final String? Function() _ownerResolver;
  final DateTime Function() _clock;
  Future<void> _tail = Future.value();
  String version = 'unknown';
  static final Set<String> _deniedKeys = {};

  String _key(String? owner) => UserScope.keyFor('local_usage_v1', owner);
  Future<T> _serial<T>(Future<T> Function() action) {
    final future = _tail.then((_) => action());
    _tail = future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return future;
  }

  Map<String, dynamic> _read(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) return {'enabled': false, 'counts': <String, dynamic>{}};
    if (raw.length > 250000)
      throw const FormatException('Usage counters too large');
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data['counts'] is! Map)
      throw const FormatException('Invalid local counters');
    return data;
  }

  bool _enabled(Map data) =>
      data['enabled'] == true && data['consent_version'] == consentVersion;
  Map<String, int> _counts(Map data) {
    final result = <String, int>{};
    final today = DateTime.utc(_clock().year, _clock().month, _clock().day);
    for (final entry in (data['counts'] as Map).entries) {
      final parts = entry.key.toString().split('|');
      if (parts.length != 3 ||
          !RegExp(r'^[0-9A-Za-z.+_-]{1,50}$').hasMatch(parts[1]) ||
          !UsageEvent.values.any((e) => e.name == parts[2]))
        continue;
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(parts[0])) continue;
      final date = DateTime.tryParse(parts[0]);
      if (date == null ||
          date.isAfter(today) ||
          today.difference(date).inDays >= 30)
        continue;
      if (entry.value is int && entry.value > 0 && entry.value <= 1000000)
        result[entry.key] = entry.value;
    }
    return result;
  }

  Future<void> _write(SharedPreferences prefs, String key, Map data) async {
    if (!await prefs.setString(key, jsonEncode(data)))
      throw StateError('Не удалось сохранить счётчики');
  }

  Future<Map<String, dynamic>> snapshot() {
    final owner = _ownerResolver();
    return _serial(() async {
      final prefs = await SharedPreferences.getInstance();
      final data = _read(prefs, _key(owner));
      if (_ownerResolver() != owner) throw StateError('Аккаунт изменился');
      final counts = _counts(data);
      if ((data['counts'] as Map).length != counts.length) {
        await _write(prefs, _key(owner), {...data, 'counts': counts});
      }
      return {
        'enabled': !_deniedKeys.contains(_key(owner)) && _enabled(data),
        'counts': counts,
      };
    });
  }

  Future<void> setEnabled(bool enabled) {
    final owner = _ownerResolver();
    _deniedKeys.add(_key(owner));
    return _serial(() async {
      final prefs = await SharedPreferences.getInstance();
      if (_ownerResolver() != owner) throw StateError('Аккаунт изменился');
      final data = _read(prefs, _key(owner));
      await _write(prefs, _key(owner), {
        'enabled': enabled,
        'consent_version': consentVersion,
        'changed_at': _clock().toUtc().toIso8601String(),
        'counts': _counts(data),
      });
      if (enabled) _deniedKeys.remove(_key(owner));
    });
  }

  /// Best effort: diagnostics never delay or fail a workout operation.
  void record(UsageEvent event) {
    final owner = _ownerResolver();
    unawaited(
      _serial(() async {
        final prefs = await SharedPreferences.getInstance();
        if (_ownerResolver() != owner) return;
        final data = _read(prefs, _key(owner));
        if (_deniedKeys.contains(_key(owner)) || !_enabled(data)) return;
        final counts = _counts(data);
        final now = _clock();
        final day =
            '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        final safeVersion = RegExp(r'^[0-9A-Za-z.+_-]{1,50}$').hasMatch(version)
            ? version
            : 'unknown';
        final key = '$day|$safeVersion|${event.name}';
        counts[key] = ((counts[key] ?? 0) + 1).clamp(0, 1000000);
        await _write(prefs, _key(owner), {...data, 'counts': counts});
      }).catchError((Object _) {}),
    );
  }

  Future<void> clear() {
    final owner = _ownerResolver();
    return _serial(() async {
      final prefs = await SharedPreferences.getInstance();
      if (_ownerResolver() != owner) throw StateError('Аккаунт изменился');
      final data = _read(prefs, _key(owner));
      await _write(prefs, _key(owner), {...data, 'counts': <String, int>{}});
    });
  }

  Future<String> exportReport() async {
    final data = await snapshot();
    final counts = data['counts'] as Map<String, int>;
    return const JsonEncoder.withIndent('  ').convert({
      'schema': 'pulsepath-usage-counters-v1',
      'automatic_upload': false,
      'retention_days': 30,
      'counters': [
        for (final entry in counts.entries)
          {
            'day': entry.key.split('|')[0],
            'version': entry.key.split('|')[1],
            'event': entry.key.split('|')[2],
            'count': entry.value,
          },
      ],
    });
  }
}
