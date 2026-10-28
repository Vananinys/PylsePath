import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/services/app_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppRelease release(int code, UpdateChannel channel) => AppRelease(
  versionCode: code,
  versionName: '1.0.$code',
  apkPath: 'android/$code/pulsepath-$code.apk',
  apkUrl: null,
  apkSha256: 'a' * 64,
  apkSizeBytes: 100,
  notes: 'test',
  channel: channel,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'stable is the default and channel choice persists separately',
    () async {
      expect(await AppUpdateService.selectedChannel(), UpdateChannel.stable);
      await AppUpdateService.selectChannel(UpdateChannel.beta);
      expect(await AppUpdateService.selectedChannel(), UpdateChannel.beta);
      await AppUpdateService.selectChannel(UpdateChannel.stable);
      expect(await AppUpdateService.selectedChannel(), UpdateChannel.stable);
    },
  );
  test('stable never offers beta even when its code is higher', () {
    final rows = [
      release(70, UpdateChannel.beta),
      release(69, UpdateChannel.stable),
    ];
    expect(
      AppUpdateService.newestCompatible(
        rows,
        68,
        UpdateChannel.stable,
      )?.versionCode,
      69,
    );
    expect(
      AppUpdateService.newestCompatible(
        rows,
        68,
        UpdateChannel.beta,
      )?.versionCode,
      70,
    );
  });
  test('leaving beta never offers an Android downgrade', () {
    expect(
      AppUpdateService.newestCompatible(
        [release(69, UpdateChannel.stable)],
        70,
        UpdateChannel.stable,
      ),
      isNull,
    );
    expect(
      AppUpdateService.newestCompatible(
        [release(71, UpdateChannel.stable)],
        70,
        UpdateChannel.stable,
      )?.versionCode,
      71,
    );
    expect(
      AppUpdateService.newestCompatible(
        [release(70, UpdateChannel.stable)],
        70,
        UpdateChannel.stable,
      ),
      isNull,
    );
  });
  test('unknown channels and invalid source commit are rejected', () {
    final json = {
      'version_code': 69,
      'version_name': '1.12.16',
      'apk_path': 'android/69/pulsepath-69.apk',
      'apk_sha256': 'a' * 64,
      'apk_size_bytes': 100,
      'notes': '',
    };
    expect(
      () => AppRelease.fromJson({...json, 'channel': 'secret'}),
      throwsFormatException,
    );
    expect(
      () => AppRelease.fromJson({...json, 'source_commit': '../../bad'}),
      throwsFormatException,
    );
    expect(
      AppRelease.fromJson({
        ...json,
        'channel': 'beta',
        'source_commit': 'b' * 40,
      }).sourceCommit,
      'b' * 40,
    );
  });
}
