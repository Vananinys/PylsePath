// Update channel selection and release metadata compatibility.
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/services/app_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../deepseek_integrity/network_guard.dart';
import 'qa_support.dart';

AppRelease release(int code, UpdateChannel channel) => AppRelease(
  versionCode: code,
  versionName: '1.0.$code',
  apkPath: 'android/$code/pulsepath-$code.apk',
  apkUrl: null,
  apkSha256: 'a' * 64,
  apkSizeBytes: 1024,
  notes: 'Проверочный выпуск',
  channel: channel,
);

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

  test(
    'a refused channel write reports failure and keeps the stable channel',
    () async {
      platform.rejectWritesTo('app_update_channel_v1');

      await expectLater(
        AppUpdateService.selectChannel(UpdateChannel.beta),
        throwsStateError,
      );
      expect(await AppUpdateService.selectedChannel(), UpdateChannel.stable);
      expect(
        (await platform.getAll()).containsKey('flutter.app_update_channel_v1'),
        isFalse,
      );

      SharedPreferences.resetStatic();
      expect(await AppUpdateService.selectedChannel(), UpdateChannel.stable);
    },
  );

  test(
    'a failing channel write cannot leave a cached beta selection',
    () async {
      platform.throwOnWritesTo('app_update_channel_v1');

      await expectLater(
        AppUpdateService.selectChannel(UpdateChannel.beta),
        throwsA(anything),
      );
      expect(
        await AppUpdateService.selectedChannel(),
        UpdateChannel.stable,
        reason:
            'the write threw, so beta exists only in the optimistic cache; '
            'the UI would claim beta while a restart returns to stable',
      );
      expect(
        (await platform.getAll()).containsKey('flutter.app_update_channel_v1'),
        isFalse,
      );

      SharedPreferences.resetStatic();
      expect(await AppUpdateService.selectedChannel(), UpdateChannel.stable);
    },
  );

  test('beta accepts a newer stable build, empty catalog and equal codes offer nothing', () async {
    expect(
      AppUpdateService.newestCompatible(
        [release(72, UpdateChannel.stable)],
        71,
        UpdateChannel.beta,
      )?.versionCode,
      72,
    );
    expect(
      AppUpdateService.newestCompatible(
        [release(70, UpdateChannel.stable), release(71, UpdateChannel.beta)],
        71,
        UpdateChannel.beta,
      ),
      isNull,
    );
    expect(
      AppUpdateService.newestCompatible(const [], 70, UpdateChannel.beta),
      isNull,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_update_channel_v1', 'nightly');
    expect(
      await AppUpdateService.selectedChannel(),
      UpdateChannel.stable,
      reason: 'an unknown stored channel must not enable beta',
    );
  });

  test('malformed release metadata is rejected before any download', () {
    final base = <String, dynamic>{
      'version_code': 4,
      'version_name': '1.0.4',
      'apk_path': 'android/4/pulsepath-4.apk',
      'apk_sha256': 'a' * 64,
      'apk_size_bytes': 42000000,
      'notes': 'Исправления и улучшения',
    };
    final invalid = <Map<String, dynamic>>[
      {...base}..remove('notes'),
      {...base, 'notes': 'x' * 2001},
      {...base, 'apk_size_bytes': 0},
      {...base, 'apk_size_bytes': 500000001},
      {...base, 'version_code': 0},
      {...base, 'version_name': ''},
      {
        ...base,
        'apk_url':
            'http://github.com/Vananinys/PylsePath/releases/download/'
            'v1.0.4/pulsepath-4.apk',
      },
      {
        ...base,
        'apk_url':
            'https://github.com/Vananinys/PylsePath/releases/download/'
            'v1.0.4/pulsepath-4.apk?download=1',
      },
      {...base, 'apk_sha256': 'A' * 64},
    ];
    for (final json in invalid) {
      expect(
        () => AppRelease.fromJson(json),
        throwsFormatException,
        reason: 'accepted malformed metadata: $json',
      );
    }

    expect(
      AppRelease.fromJson({
        ...base,
        'apk_url':
            'https://github.com/Vananinys/PylsePath/releases/download/'
            'v1.0.4/pulsepath-4.apk',
      }).versionCode,
      4,
    );
  });
}
