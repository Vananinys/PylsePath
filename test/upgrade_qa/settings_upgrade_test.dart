// Settings are flat SharedPreferences keys without a schema version.
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart'
    show SportMode;
import 'package:pulsepath/data/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../deepseek_integrity/network_guard.dart';
import 'qa_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(NetworkGuard.install);
  tearDownAll(NetworkGuard.restore);

  late QaPreferencesStore platform;
  late SharedPreferencesStorePlatform previousPlatform;

  setUp(() {
    previousPlatform = SharedPreferencesStorePlatform.instance;
    platform = QaPreferencesStore();
    SharedPreferencesStorePlatform.instance = platform;
    SharedPreferences.resetStatic();
  });

  tearDown(() {
    SharedPreferencesStorePlatform.instance = previousPlatform;
    SharedPreferences.resetStatic();
  });

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  test(
    'one wrong-typed legacy setting does not discard unrelated valid settings',
    () async {
      final store = await prefs();
      await store.setBool('ride_auto_pause_enabled', false);
      await store.setString('ride_sport_mode', 'walking');
      // An older/foreign writer stored the flag as a number.
      await store.setInt('ride_background_tracking', 1);

      final settings = AppSettings();
      await settings.load();

      expect(
        settings.autoPauseEnabled,
        isFalse,
        reason: 'the valid auto-pause choice must not be reset by another key',
      );
      expect(
        settings.sportMode,
        SportMode.walking,
        reason: 'the valid sport mode must not be reset by another key',
      );
    },
  );

  test('unknown enum names and out-of-range counters fall back without rewriting storage', () async {
    final store = await prefs();
    await store.setString('ride_sport_mode', 'submarine');
    await store.setInt('workout_water_reminder_minutes', 999);
    await store.setBool('gear_advisor_experimental', true);
    final before = Map<String, Object>.from((await platform.getAll()));

    final settings = AppSettings();
    await settings.load();

    expect(settings.sportMode, SportMode.vehicle);
    expect(settings.waterReminderMinutes, 0);
    expect(settings.gearLabEnabled, isTrue);
    expect(
      await platform.getAll(),
      before,
      reason: 'loading settings must be read-only',
    );
  });
}
