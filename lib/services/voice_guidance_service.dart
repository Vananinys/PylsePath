import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/route_step.dart';

/// Uses the phone's installed Russian voice. No audio files or cloud synthesis.
class VoiceGuidanceService extends ChangeNotifier {
  VoiceGuidanceService._();
  static final instance = VoiceGuidanceService._();
  static const _channel = MethodChannel('pulsepath/voice_guidance');
  Future<void>? _loading;
  bool navigationEnabled = true;
  double volume = 1;
  bool briefTurns = false;
  bool remindersEnabled = true;
  String? error;
  int _generation = 0;
  RouteStep? _step;
  bool _early = false, _near = false, _arrived = false;
  DateTime? _lastNavigation;

  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    navigationEnabled = prefs.getBool('voice_navigation') ?? true;
    remindersEnabled = prefs.getBool('voice_reminders') ?? true;
    final rawVolume = prefs.get('voice_volume');
    volume = rawVolume is num && rawVolume.isFinite
        ? rawVolume.toDouble().clamp(0, 1)
        : 1;
    briefTurns = prefs.get('voice_brief_turns') == true;
    notifyListeners();
  }

  Future<void> configure({
    bool? navigation,
    bool? reminders,
    double? speechVolume,
    bool? brief,
  }) async {
    await load();
    final prefs = await SharedPreferences.getInstance();
    if (speechVolume != null && speechVolume.isFinite) {
      final next = speechVolume.clamp(0.0, 1.0);
      if (!await prefs.setDouble('voice_volume', next))
        throw StateError('Не удалось сохранить громкость');
      volume = next;
    }
    if (brief != null) {
      if (!await prefs.setBool('voice_brief_turns', brief))
        throw StateError('Не удалось сохранить частоту');
      briefTurns = brief;
    }
    if (navigation != null) {
      await prefs.setBool('voice_navigation', navigation);
      navigationEnabled = navigation;
    }
    if (reminders != null) {
      await prefs.setBool('voice_reminders', reminders);
      remindersEnabled = reminders;
    }
    await stop();
    resetTurns();
    notifyListeners();
  }

  void resetTurns() {
    _step = null;
    _early = false;
    _near = false;
    _arrived = false;
  }

  Future<void> stop() async {
    _generation++;
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  Future<bool> _speak(
    String text, {
    required bool navigation,
    bool preview = false,
  }) async {
    final generation = _generation;
    try {
      await load();
      if (generation != _generation) return false;
      if (!preview && !(navigation ? navigationEnabled : remindersEnabled)) {
        return false;
      }
      if (!supported) {
        error = 'Озвучивание пока доступно на Android';
        notifyListeners();
        return false;
      }
      if (!navigation &&
          !preview &&
          _lastNavigation != null &&
          DateTime.now().difference(_lastNavigation!) <
              const Duration(seconds: 10)) {
        return false;
      }
      final ready = await _channel.invokeMethod<bool>('prepare');
      if (generation != _generation || ready != true) return false;
      final accepted = await _channel.invokeMethod<bool>('speak', {
        'text': text,
        'navigation': navigation,
        'volume': volume,
      });
      if (accepted == true) {
        error = null;
        if (navigation && !preview) _lastNavigation = DateTime.now();
      }
      notifyListeners();
      return accepted == true;
    } on PlatformException catch (failure) {
      error = failure.message ?? 'Голосовой движок недоступен';
      notifyListeners();
      return false;
    } catch (_) {
      error = 'Не удалось включить голос. Проверьте синтез речи в настройках телефона.';
      notifyListeners();
      return false;
    }
  }

  Future<bool> preview() => _speak(
    'Через сто метров поверните направо. Не забудьте сделать глоток воды.',
    navigation: true,
    preview: true,
  );

  Future<void> openVoiceSettings() async {
    if (supported) await _channel.invokeMethod<void>('settings');
  }

  void reminder(String text) => unawaited(_speak(text, navigation: false));

  void deviation() {
    resetTurns();
    unawaited(
      _speak(
        'Вы отклонились от маршрута. Проверьте путь на карте.',
        navigation: true,
      ),
    );
  }

  /// Called only on a good GPS fix projected onto the active route.
  void turn(RouteStep step, double meters, double speedKmh) {
    if (!meters.isFinite || meters < 0) return;
    if (!identical(_step, step)) {
      _step = step;
      _early = false;
      _near = false;
      _arrived = false;
    }
    final speed = speedKmh.isFinite ? speedKmh.clamp(0.0, 70.0) / 3.6 : 0.0;
    final early = (speed * 20).clamp(80.0, 250.0);
    final near = (speed * 5).clamp(15.0, 50.0);
    if (briefTurns && meters > near) return;
    if (meters > early) return;
    final instruction = step.instruction;
    if (instruction == 'Начните движение' ||
        instruction == 'Продолжайте движение') {
      return;
    }
    if (instruction == 'Вы прибыли' && meters <= 12 && !_arrived) {
      _arrived = true;
      _near = true;
      _early = true;
      unawaited(_speak('Вы прибыли', navigation: true));
      return;
    }
    final street = step.streetName.trim();
    final direction = street.isEmpty ? instruction : '$instruction. $street';
    if (meters <= near && !_near) {
      _near = true;
      _early = true;
      final arrival = instruction == 'Вы прибыли';
      unawaited(
        _speak(
          arrival
              ? (meters <= 12
                    ? 'Вы прибыли'
                    : 'Финиш рядом, впереди ${meters.round()} метров')
              : 'Сейчас. $direction',
          navigation: true,
        ),
      );
    } else if (!_early) {
      _early = true;
      final rounded = (meters / 10).round() * 10;
      unawaited(
        _speak(
          instruction == 'Вы прибыли'
              ? 'До финиша $rounded метров'
              : 'Через $rounded метров. $direction',
          navigation: true,
        ),
      );
    }
  }
}
