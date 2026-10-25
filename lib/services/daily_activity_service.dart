import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/user_scope.dart';

export 'recording_daily_activity_service.dart';

/// Retained for compatibility/reference; the daily activity UI uses Recording API.
class LegacyDailyActivityService extends ChangeNotifier {
  static final instance = LegacyDailyActivityService._();
  LegacyDailyActivityService._();
  static const _methods = MethodChannel('pulsepath/steps');
  static const _events = EventChannel('pulsepath/step_events');
  StreamSubscription<dynamic>? _subscription;
  Timer? _dayTimer;
  String? _owner;
  SharedPreferences? _prefs;
  bool enabled = false;
  bool available = false;
  bool ready = false;
  String? notice;
  int goal = 6000;
  double strideMeters = .7;
  String _day = '';
  int _steps = 0;
  int? _lastCount;
  int? _lastUptime;
  final Map<String, int> history = {};
  String get _key => UserScope.keyFor('daily_steps_v1', _owner);
  String get today => DateTime.now().toIso8601String().substring(0, 10);
  int get steps => _day == today ? _steps : 0;
  double get distanceKm => steps * strideMeters / 1000;
  double activeCalories(double weightKg) => distanceKm * weightKg * .5;
  double get progress => (steps / goal).clamp(0, 1);

  Future<void> initialize() async {
    await stop();
    final owner = UserScope.currentUserId();
    _owner = owner;
    ready = false;
    enabled = false;
    available = false;
    notice = null;
    _steps = 0;
    _lastCount = null;
    _lastUptime = null;
    history.clear();
    goal = 6000;
    strideMeters = .7;
    _day = today;
    try {
      _prefs = await SharedPreferences.getInstance();
      if (_owner != owner) return;
      final saved = _prefs!.getString(_key);
      if (saved != null) {
        final raw = jsonDecode(saved) as Map<String, dynamic>;
        enabled = raw['enabled'] == true;
        goal = ((raw['goal'] as num?)?.toInt() ?? 6000).clamp(1000, 50000);
        strideMeters = ((raw['stride'] as num?)?.toDouble() ?? .7).clamp(
          .4,
          1.2,
        );
        _day = raw['day'] as String? ?? today;
        _steps = ((raw['steps'] as num?)?.toInt() ?? 0).clamp(0, 500000);
        _lastCount = (raw['last_count'] as num?)?.toInt();
        _lastUptime = (raw['last_uptime'] as num?)?.toInt();
        final old = raw['history'];
        if (old is Map) {
          for (final entry in old.entries) {
            if (entry.key is String && entry.value is num) {
              history[entry.key] = (entry.value as num).toInt().clamp(
                0,
                500000,
              );
            }
          }
        }
      }
      _rollDay();
      available =
          Platform.isAndroid &&
          await _methods.invokeMethod<bool>('available') == true;
      if (!available) enabled = false;
      if (enabled &&
          available &&
          await Permission.activityRecognition.isGranted) {
        _listen();
      }
      _dayTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        _rollDay();
        notifyListeners();
      });
    } catch (error) {
      notice = 'Не удалось запустить шагомер. Попробуйте включить его ещё раз.';
      debugPrint('[DailyActivity] $error');
    } finally {
      ready = true;
      notifyListeners();
    }
  }

  void _rollDay() {
    if (_day == today) return;
    if (_day.isNotEmpty) history[_day] = _steps;
    _day = today;
    _steps = 0;
    _lastCount = null;
    _lastUptime = null;
    unawaited(_save());
  }

  Future<void> setEnabled(bool value) async {
    if (value && available) {
      final permission = await Permission.activityRecognition.request();
      if (!permission.isGranted) {
        notice = 'Доступ к физической активности не разрешён. Его можно включить в настройках телефона.';
        notifyListeners();
        return;
      }
    }
    enabled = value && available;
    notice = null;
    if (enabled) {
      _listen();
    } else {
      await _subscription?.cancel();
      _subscription = null;
      _lastCount = null;
      _lastUptime = null;
    }
    await _save();
    notifyListeners();
  }

  void _listen() {
    if (_subscription != null) return;
    _subscription = _events.receiveBroadcastStream().listen(
      (event) {
        if (UserScope.currentUserId() != _owner || !enabled || event is! Map) {
          return;
        }
        final count = (event['count'] as num?)?.toInt();
        final uptime = (event['uptime'] as num?)?.toInt();
        if (count == null || uptime == null || count < 0) return;
        _rollDay();
        if (_lastCount != null &&
            _lastUptime != null &&
            count >= _lastCount! &&
            uptime >= _lastUptime!) {
          _steps += count - _lastCount!;
        }
        _lastCount = count;
        _lastUptime = uptime;
        notice = null;
        unawaited(_save());
        notifyListeners();
      },
      onError: (Object error) {
        notice = 'Датчик недоступен. Выключите и снова включите шагомер.';
        debugPrint('[DailyActivity] $error');
        notifyListeners();
      },
    );
  }

  Future<void> configure({int? target, double? stride}) async {
    if (target != null) goal = target.clamp(1000, 50000);
    if (stride != null) strideMeters = stride.clamp(.4, 1.2);
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    if (_prefs == null || UserScope.currentUserId() != _owner) return;
    final keys = history.keys.toList()..sort();
    while (keys.length > 7) {
      history.remove(keys.removeAt(0));
    }
    await _prefs!.setString(
      _key,
      jsonEncode({
        'enabled': enabled,
        'goal': goal,
        'stride': strideMeters,
        'day': _day,
        'steps': _steps,
        'last_count': _lastCount,
        'last_uptime': _lastUptime,
        'history': history,
      }),
    );
  }

  Future<void> stop() async {
    _dayTimer?.cancel();
    _dayTimer = null;
    await _subscription?.cancel();
    _subscription = null;
  }
}
