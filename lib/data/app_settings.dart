import 'package:shared_preferences/shared_preferences.dart';

import '../controllers/map_navigation_controller.dart' show SportMode;
import '../services/workout_reminder_clock.dart';

/// Настройки заезда, сохраняемые между сессиями (SharedPreferences).
///
/// Живые тумблеры заезда — в HUD предзапуска и активной панели; здесь
/// хранятся значения по умолчанию, которые контроллер подхватывает при старте
/// приложения. Тёмная тема отключена и в настройках не живёт.
class AppSettings {
  static const String _autoPauseKey = 'ride_auto_pause_enabled';
  static const String _sportModeKey = 'ride_sport_mode';
  static const String _backgroundKey = 'ride_background_tracking';
  static const String _shareLivePositionKey = 'privacy_share_live_position';

  bool _autoPauseEnabled = true;
  SportMode _sportMode = SportMode.vehicle;
  bool _backgroundTracking = true;
  bool _shareLivePosition = false;
  bool _gearLabEnabled = false;
  int _waterReminderMinutes = 0;
  int get waterReminderMinutes => _waterReminderMinutes;
  bool get gearLabEnabled => _gearLabEnabled;

  /// Автопауза включена по умолчанию.
  bool get autoPauseEnabled => _autoPauseEnabled;

  /// Последний вид тренировки (вело/пешком/бег).
  SportMode get sportMode => _sportMode;

  /// Фоновый режим: трек пишется и с выключенным экраном
  /// (foreground service с уведомлением на Android).
  bool get backgroundTracking => _backgroundTracking;

  /// Приватность: транслировать ли живую позицию друзьям во время заезда.
  bool get shareLivePosition => _shareLivePosition;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _backgroundTracking = prefs.get(_backgroundKey) is bool
          ? prefs.get(_backgroundKey) as bool
          : true;
      _autoPauseEnabled = prefs.get(_autoPauseKey) is bool
          ? prefs.get(_autoPauseKey) as bool
          : true;
      _shareLivePosition = prefs.get(_shareLivePositionKey) is bool
          ? prefs.get(_shareLivePositionKey) as bool
          : false;
      _gearLabEnabled = prefs.get('gear_advisor_experimental') is bool
          ? prefs.get('gear_advisor_experimental') as bool
          : false;
      final waterMinutes = prefs.get('workout_water_reminder_minutes') is int
          ? prefs.get('workout_water_reminder_minutes') as int
          : 0;
      _waterReminderMinutes =
          WorkoutReminderClock.intervals.contains(waterMinutes)
          ? waterMinutes
          : 0;
      final modeName = prefs.get(_sportModeKey);
      _sportMode =
          SportMode.values.where((mode) => mode.name == modeName).firstOrNull ??
          SportMode.vehicle;
    } catch (_) {
      _autoPauseEnabled = true;
      _sportMode = SportMode.vehicle;
    }
  }

  Future<void> setAutoPauseEnabled(bool value) async {
    _autoPauseEnabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoPauseKey, value);
    } catch (_) {}
  }

  Future<void> setGearLabEnabled(bool value) async {
    _gearLabEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('gear_advisor_experimental', value);
  }

  Future<void> setWaterReminderMinutes(int minutes) async {
    if (!WorkoutReminderClock.intervals.contains(minutes)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('workout_water_reminder_minutes', minutes);
    _waterReminderMinutes = minutes;
  }

  Future<void> setSportMode(SportMode value) async {
    _sportMode = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sportModeKey, value.name);
    } catch (_) {}
  }

  Future<void> setBackgroundTracking(bool value) async {
    _backgroundTracking = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_backgroundKey, value);
    } catch (_) {}
  }

  Future<void> setShareLivePosition(bool value) async {
    _shareLivePosition = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_shareLivePositionKey, value);
    } catch (_) {}
  }
}
