import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/user_scope.dart';
import '../models/walking_steps.dart';
import '../utils/ride_id.dart';
import 'recording_daily_activity_service.dart';

class WorkoutStepTracker extends ChangeNotifier {
  WorkoutStepTracker({
    StepRecordingPlatform? platform,
    DateTime Function()? now,
  }) : _platform = platform ?? StepRecordingPlatform(),
       _now = now ?? DateTime.now;
  final StepRecordingPlatform _platform;
  final DateTime Function() _now;
  static const _events = EventChannel('pulsepath/step_events');
  String? _owner;
  String _device = '';
  List<StepWindow> _windows = [];
  double _stride = .7;
  bool enabled = false, _disposed = false, _reading = false;
  String? notice;
  Timer? _timer;
  StreamSubscription<dynamic>? _sensor;
  int _generation = 0;
  int? _raw, _rawAt;
  int get count => _windows.fold(0, (sum, w) => sum + w.steps);
  double get distanceKm => count * _stride / 1000;
  WalkingSteps? get snapshot => enabled
      ? WalkingSteps(
          device: _device,
          windows: List.unmodifiable(_windows),
          observedAt: _now().millisecondsSinceEpoch,
          stride: _stride,
        )
      : null;
  static Future<String> localDevice() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('walking_step_device_v1');
    if (id == null) {
      id = newRideId();
      if (!await prefs.setString('walking_step_device_v1', id))
        throw StateError('Step device cannot be stored');
    }
    return id;
  }

  void start({required bool foot, double stride = .7}) {
    stop();
    enabled = foot;
    notice = null;
    _owner = UserScope.currentUserId();
    _stride = stride;
    _windows = [];
    _device = '';
    _raw = null;
    _rawAt = null;
    if (!foot) return;
    resume();
  }

  void restore(WalkingSteps? saved) {
    stop();
    enabled = saved != null;
    _owner = UserScope.currentUserId();
    _device = saved?.device ?? '';
    _windows = List.of(saved?.windows ?? []);
    _stride = saved?.stride ?? .7;
    _raw = null;
    _rawAt = null;
  }

  void resume() {
    if (!enabled ||
        _disposed ||
        (_windows.isNotEmpty && _windows.last.end == null))
      return;
    if (_windows.length >= 256) {
      notice = 'Достигнут предел отрезков шагомера';
      return;
    }
    _windows.add(StepWindow(start: _now().millisecondsSinceEpoch));
    _raw = null;
    _rawAt = null;
    if (_platform.supported) {
      if (!kIsWeb && Platform.isAndroid)
        _sensor ??= _events.receiveBroadcastStream().listen(
          (event) {
            if (event is Map) acceptSensor(event);
          },
          onError: (Object error) {
            /* Recording API remains the background source. */
          },
        );
      _timer ??= Timer.periodic(
        const Duration(seconds: 15),
        (_) => unawaited(refresh()),
      );
      unawaited(refresh());
    }
  }

  void pause() {
    if (!enabled || _windows.isEmpty || _windows.last.end != null) return;
    _windows[_windows.length - 1] = _windows.last.closed(
      _now().millisecondsSinceEpoch,
    );
    _timer?.cancel();
    _timer = null;
    _raw = null;
    _rawAt = null;
    unawaited(_sensor?.cancel());
    _sensor = null;
    if (_platform.supported) unawaited(refresh());
  }

  @visibleForTesting
  void acceptSensor(Map<dynamic, dynamic> event) {
    if (_disposed || !enabled || UserScope.currentUserId() != _owner) return;
    final value = event['count'], at = event['at'];
    if (value is! num ||
        !value.isFinite ||
        value < 0 ||
        at is! num ||
        !at.isFinite)
      return;
    final raw = value.toInt(), time = at.toInt();
    final index = _windows.indexWhere((w) => w.end == null && w.contains(time));
    if (index < 0) return;
    final previous = _raw, previousAt = _rawAt;
    if (previousAt != null && time < previousAt) return;
    if (time > _now().millisecondsSinceEpoch + 2000) return;
    _raw = raw;
    _rawAt = time;
    if (previous == null ||
        previousAt == null ||
        time < previousAt ||
        !_windows[index].contains(previousAt))
      return;
    final delta = raw - previous;
    if (delta <= 0 || delta > 10000) return;
    final w = _windows[index];
    _windows[index] = StepWindow(
      start: w.start,
      end: w.end,
      recorded: w.recorded,
      live: (w.live + delta).clamp(0, 500000),
    );
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_reading ||
        !enabled ||
        _disposed ||
        !_platform.supported ||
        UserScope.currentUserId() != _owner)
      return;
    _reading = true;
    final generation = _generation;
    try {
      final device = await localDevice();
      if (generation != _generation ||
          _disposed ||
          UserScope.currentUserId() != _owner)
        return;
      if (_device.isNotEmpty && _device != device) {
        notice = 'Шаги этой тренировки записаны на другом устройстве';
        return;
      }
      _device = device;
      final sent = List<StepWindow>.of(_windows);
      final result = await _platform
          .invoke('workoutSteps', {
            'owner': _owner ?? 'guest',
            'windows': [
              for (final w in sent)
                {
                  'start': w.start,
                  'end': w.end ?? _now().millisecondsSinceEpoch,
                },
            ],
          })
          .timeout(const Duration(seconds: 35));
      if (generation != _generation ||
          _disposed ||
          UserScope.currentUserId() != _owner)
        return;
      final totals = result['totals'];
      if (totals is! List || totals.length != sent.length)
        throw StateError('Invalid step response');
      for (var i = 0; i < totals.length && i < _windows.length; i++) {
        final n = totals[i];
        if (n is! num || !n.isFinite || n < 0) continue;
        final w = _windows[i];
        if (w.start != sent[i].start) continue;
        _windows[i] = StepWindow(
          start: w.start,
          end: w.end,
          recorded: math.max(w.recorded, n.toInt().clamp(0, 500000)),
          live: w.live,
        );
      }
      notice = 'Google может обновлять шаги с задержкой';
    } catch (_) {
      if (generation == _generation && !_disposed) notice = 'Шаги Google пока недоступны. Проверьте разрешение физической активности.';
    } finally {
      _reading = false;
      if (!_disposed && generation == _generation) notifyListeners();
    }
  }

  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    unawaited(_sensor?.cancel());
    _sensor = null;
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    super.dispose();
  }
}
