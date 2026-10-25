import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/user_scope.dart';
import '../data/progress_backup_repository.dart';

/// Native background collection; Dart only reads totals when someone views them.
class StepRecordingPlatform {
  static const channel = MethodChannel('pulsepath/step_recording');
  bool get supported => Platform.isAndroid;
  Future<Map<dynamic, dynamic>> invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async =>
      await channel.invokeMapMethod<dynamic, dynamic>(method, arguments) ?? {};
  Future<bool> requestPermission() async =>
      (await Permission.activityRecognition.request()).isGranted;
  Future<void> resolveServices() =>
      channel.invokeMethod<void>('resolveServices');
}

class DailyActivityService extends ChangeNotifier {
  static final instance = DailyActivityService._();
  DailyActivityService._()
    : _platform = StepRecordingPlatform(),
      _ownerResolver = UserScope.currentUserId,
      _now = DateTime.now,
      _backupEnabled = true;

  @visibleForTesting
  factory DailyActivityService.forTesting({
    required StepRecordingPlatform platform,
    required String? Function() owner,
    required DateTime Function() now,
  }) => DailyActivityService._injected(platform, owner, now);
  DailyActivityService._injected(this._platform, this._ownerResolver, this._now)
    : _backupEnabled = false;

  final StepRecordingPlatform _platform;
  final String? Function() _ownerResolver;
  final DateTime Function() _now;
  final bool _backupEnabled;
  ProgressBackupRepository? _backup;
  int _settingsUpdatedAt = 0;
  DateTime? cloudSyncedAt;
  bool cloudPending = false;
  SharedPreferences? _prefs;
  String? _owner;
  int _generation = 0;
  Future<void> _queue = Future<void>.value();
  Timer? _timer;
  int _viewers = 0;
  bool _foreground = true;
  bool _refreshQueued = false;
  bool enabled = false;
  bool available = false;
  bool ready = false;
  bool busy = false;
  bool permissionGranted = false;
  String? notice;
  int goal = 6000;
  double strideMeters = .7;
  DateTime? lastSyncedAt;
  final Map<String, int> _days = {};

  String get today => _now().toIso8601String().substring(0, 10);
  int get steps => _ownerResolver() == _owner ? (_days[today] ?? 0) : 0;
  Map<String, int> get history =>
      _ownerResolver() == _owner ? (Map.of(_days)..remove(today)) : {};
  double get distanceKm => steps * strideMeters / 1000;
  double activeCalories(double weightKg) => distanceKm * weightKg * .5;
  double get progress => (steps / goal).clamp(0, 1);
  String get _key => UserScope.keyFor('daily_steps_recording_v1', _owner);
  Map<String, dynamic> get _arguments => {'owner': _owner ?? 'guest'};
  bool _current(int generation) =>
      generation == _generation && _ownerResolver() == _owner;

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _queue.then((_) => action());
    // One failed operation must not prevent retrying or switching accounts.
    _queue = next.catchError((Object error) {
      debugPrint('[StepRecording] $error');
    });
    return next;
  }

  Future<void> initialize() {
    final generation = ++_generation;
    final owner = _ownerResolver();
    _timer?.cancel();
    return _enqueue(() async {
      if (generation != _generation) return;
      _owner = owner;
      _backup = _backupEnabled ? ProgressBackupRepository() : null;
      _settingsUpdatedAt = 0;
      cloudSyncedAt = null;
      cloudPending = false;
      _days.clear();
      enabled = false;
      available = false;
      ready = false;
      busy = false;
      notice = null;
      lastSyncedAt = null;
      goal = 6000;
      strideMeters = .7;
      notifyListeners();
      try {
        _prefs = await SharedPreferences.getInstance();
        if (!_current(generation)) return;
        final saved = _prefs!.getString(_key);
        final legacy = _prefs!.getString(
          UserScope.keyFor('daily_steps_v1', _owner),
        );
        final raw = jsonDecode(saved ?? legacy ?? '{}') as Map<String, dynamic>;
        _settingsUpdatedAt = (raw['settingsUpdatedAt'] as num?)?.toInt() ?? 0;
        enabled = raw['enabled'] == true;
        goal = ((raw['goal'] as num?)?.toInt() ?? 6000).clamp(1000, 50000);
        strideMeters = ((raw['stride'] as num?)?.toDouble() ?? .7).clamp(
          .4,
          1.2,
        );
        _mergeDays(raw['days'] ?? raw['history']);
        if (saved == null && raw['day'] is String && raw['steps'] is num) {
          _mergeDays({raw['day']: raw['steps']});
        }
        final stamp = (raw['lastSyncedAt'] as num?)?.toInt() ?? 0;
        if (stamp > 0) {
          lastSyncedAt = DateTime.fromMillisecondsSinceEpoch(stamp);
        }
        await _restoreBackup(generation);
        if (!_current(generation)) return;
        if (!_platform.supported) {
          enabled = false;
          notice = 'Этот способ подсчёта доступен на Android с сервисами Google Play.';
          return;
        }
        await _readStatus();
        if (!_current(generation)) return;
        final snapshot = await _platform.invoke('initialize', {
          ..._arguments,
          'seedDays': Map.of(_days),
          'legacyEnabled': enabled,
        });
        if (!_current(generation)) return;
        _apply(snapshot);
        await _save();
      } catch (error) {
        if (_current(generation)) _report(error);
      } finally {
        if (_current(generation)) {
          ready = true;
          _updateTimer();
          notifyListeners();
        }
      }
    });
  }

  Future<void> _readStatus() async {
    final status = await _platform.invoke('status');
    available = status['available'] == true;
    permissionGranted = status['permissionGranted'] == true;
  }

  void _mergeDays(dynamic values) {
    if (values is! Map) return;
    for (final entry in values.entries) {
      final day = entry.key;
      if (day is! String ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day) ||
          day.compareTo(today) > 0 ||
          entry.value is! num) {
        continue;
      }
      final value = entry.value as num;
      if (!value.isFinite || value < 0) continue;
      // Native values already include migrated/previous sessions. Never add them again.
      if (value.toInt() > (_days[day] ?? -1)) _days[day] = value.toInt();
    }
  }

  void _apply(Map<dynamic, dynamic> snapshot) {
    enabled = snapshot['enabled'] == true;
    _mergeDays(snapshot['days']);
    final stamp = (snapshot['lastSyncedAt'] as num?)?.toInt() ?? 0;
    if (stamp > 0) lastSyncedAt = DateTime.fromMillisecondsSinceEpoch(stamp);
    notice = snapshot['warning'] as String?;
    if (enabled && !permissionGranted) {
      notice = 'Разрешите физическую активность в настройках телефона, чтобы продолжить подсчёт.';
    } else if (!available) {
      notice = 'Для фонового подсчёта нужны доступные и обновлённые сервисы Google Play.';
    }
  }

  Future<void> refresh() async {
    if (_refreshQueued || !ready || !_platform.supported) return;
    _refreshQueued = true;
    final generation = _generation;
    try {
      await _enqueue(() async {
        if (!_current(generation)) return;
        try {
          await _readStatus();
          if (!_current(generation)) return;
          final snapshot = await _platform.invoke('refresh', _arguments);
          if (!_current(generation)) return;
          _apply(snapshot);
          await _save();
        } catch (error) {
          if (_current(generation)) _report(error);
        } finally {
          if (_current(generation)) notifyListeners();
        }
      });
    } finally {
      _refreshQueued = false;
    }
  }

  Future<void> setEnabled(bool value) {
    final generation = _generation;
    return _enqueue(() async {
      if (!_current(generation) || !_platform.supported) return;
      busy = true;
      notifyListeners();
      try {
        if (value && !await _platform.requestPermission()) {
          permissionGranted = false;
          notice = 'Доступ к физической активности не разрешён. Его можно включить в настройках телефона.';
          return;
        }
        if (!_current(generation)) return;
        await _readStatus();
        if (!_current(generation)) return;
        final snapshot = await _platform.invoke('setEnabled', {
          ..._arguments,
          'enabled': value,
        });
        if (!_current(generation)) return;
        _apply(snapshot);
        await _save();
      } catch (error) {
        if (_current(generation)) _report(error);
      } finally {
        if (_current(generation)) {
          busy = false;
          _updateTimer();
          notifyListeners();
        }
      }
    });
  }

  void _report(Object error) {
    debugPrint('[StepRecording] $error');
    final code = error is PlatformException ? error.code : '';
    notice = code == 'PERMISSION'
        ? 'Разрешите физическую активность в настройках телефона, чтобы продолжить подсчёт.'
        : code == 'PLAY_SERVICES'
        ? 'Обновите или включите сервисы Google Play для фонового подсчёта шагов.'
        : 'Не удалось обновить шаги. Сохранённые данные на месте; попробуйте ещё раз.';
  }

  Future<void> configure({int? target, double? stride}) {
    final generation = _generation;
    return _enqueue(() async {
      if (!_current(generation)) return;
      if (target != null) goal = target.clamp(1000, 50000);
      if (stride != null) strideMeters = stride.clamp(.4, 1.2);
      _settingsUpdatedAt = _now().millisecondsSinceEpoch;
      await _save();
      notifyListeners();
    });
  }

  Future<void> _save() async {
    if (_prefs == null || _ownerResolver() != _owner) return;
    final value = jsonEncode({
      'enabled': enabled,
      'goal': goal,
      'stride': strideMeters,
      'days': _days,
      'lastSyncedAt': lastSyncedAt?.millisecondsSinceEpoch,
      'settingsUpdatedAt': _settingsUpdatedAt,
    });
    if (_prefs!.getString(_key) != value) await _prefs!.setString(_key, value);
    await _backup?.update({
      'days': _days,
      'preferences': {
        'goal': goal,
        'stride': strideMeters,
        'updatedAt': _settingsUpdatedAt,
      },
    });
    if (_backup != null)
      cloudPending = (await _backup!.read())['pending'] == true;
  }

  Future<void> _restoreBackup(int generation) async {
    final state = await _backup?.read();
    if (state == null || !_current(generation)) return;
    _mergeDays(state['days']);
    final preferences = state['preferences'] as Map? ?? {};
    final stamp = (preferences['updatedAt'] as num?)?.toInt() ?? 0;
    if (preferences.isNotEmpty && stamp >= _settingsUpdatedAt) {
      goal = ((preferences['goal'] as num?)?.toInt() ?? goal).clamp(
        1000,
        50000,
      );
      strideMeters =
          ((preferences['stride'] as num?)?.toDouble() ?? strideMeters).clamp(
            .4,
            1.2,
          );
      _settingsUpdatedAt = stamp;
    }
    cloudPending = state['pending'] == true;
    cloudSyncedAt = DateTime.tryParse(state['cloudSyncedAt'] as String? ?? '');
  }

  Future<void> restoreCloudBackup() => _enqueue(() async {
    final generation = _generation;
    await _restoreBackup(generation);
    if (_current(generation)) {
      if (_platform.supported && available) {
        try {
          final snapshot = await _platform.invoke('initialize', {
            ..._arguments,
            'seedDays': Map.of(_days),
            'legacyEnabled': false,
          });
          if (!_current(generation)) return;
          _apply(snapshot);
        } catch (error) {
          if (_current(generation)) _report(error);
        }
      }
      await _save();
      notifyListeners();
    }
  });

  Future<void> resolveServices() async {
    if (_platform.supported) await _platform.resolveServices();
  }

  void beginLiveUpdates() {
    _viewers++;
    _updateTimer();
    unawaited(refresh());
  }

  void endLiveUpdates() {
    if (_viewers > 0) _viewers--;
    _updateTimer();
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    _updateTimer();
    if (foreground) unawaited(refresh());
  }

  void _updateTimer() {
    _timer?.cancel();
    _timer = null;
    if (ready && enabled && _foreground && _viewers > 0) {
      _timer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => unawaited(refresh()),
      );
    }
  }

  /// Closing the map/app stops UI work, never the system recording subscription.
  Future<void> stop() async {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _viewers = 0;
  }
}
