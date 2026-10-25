import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/services/app_update_service.dart';

void main() {
  final release = <String, dynamic>{
    'version_code': 4,
    'version_name': '1.0.1',
    'apk_path': 'android/4/pulsepath-4.apk',
    'apk_sha256': 'a' * 64,
    'apk_size_bytes': 42000000,
    'notes': 'Исправления и улучшения',
  };

  test('accepts official GitHub release and rejects a different repository', () {
    expect(
      AppRelease.fromJson({
        ...release,
        'apk_url': 'https://github.com/Vananinys/PylsePath/releases/download/v1.0.1/pulsepath-4.apk',
      }).versionCode,
      4,
    );
    for (final repository in ['attacker/PylsePath', 'Vananinys/other']) {
      expect(
        () => AppRelease.fromJson({
          ...release,
          'apk_url':
              'https://github.com/$repository/releases/download/v1.0.1/pulsepath-4.apk',
        }),
        throwsFormatException,
      );
    }
  });

  test('accepts a versioned APK with a SHA-256 digest', () {
    final parsed = AppRelease.fromJson(release);
    expect(parsed.versionCode, 4);
    expect(parsed.apkPath, 'android/4/pulsepath-4.apk');
  });

  test('rejects an APK path for a different version', () {
    expect(
      () => AppRelease.fromJson({
        ...release,
        'apk_path': 'android/5/pulsepath-5.apk',
      }),
      throwsFormatException,
    );
  });

  test('rejects a malformed digest before download', () {
    expect(
      () => AppRelease.fromJson({...release, 'apk_sha256': 'untrusted'}),
      throwsFormatException,
    );
  });
}
