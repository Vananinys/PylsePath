import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the on-device privacy invariants of the Android build so an
/// accidental change cannot silently enable cloud backups, device-to-device
/// transfer or cleartext traffic for E2EE-protected chats. Pure file checks:
/// no device, network or real data involved.
void main() {
  const manifestPath = 'android/app/src/main/AndroidManifest.xml';
  const backupPath = 'android/app/src/main/res/xml/backup_rules.xml';
  const extractionPath =
      'android/app/src/main/res/xml/data_extraction_rules.xml';

  String read(String path) => File(path).readAsStringSync();

  test('manifest keeps backups disabled and cleartext off', () {
    final manifest = read(manifestPath);
    expect(manifest.contains('android:allowBackup="false"'), isTrue,
        reason: 'allowBackup=true включил бы облачные копии сессий и ключей');
    expect(manifest.contains('android:usesCleartextTraffic="false"'), isTrue,
        reason: 'cleartext раскрыл бы E2EE-трафик');
    expect(manifest.contains('android:fullBackupContent="@xml/backup_rules"'),
        isTrue);
    expect(manifest.contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
        isTrue,
        reason: 'без dataExtractionRules Android 12+ мог бы разрешить '
            'device-to-device перенос вопреки allowBackup=false');
  });

  test('cloud backup excludes every storage domain', () {
    final rules = read(backupPath);
    for (final domain in [
      'root',
      'file',
      'database',
      'sharedpref',
      'external',
    ]) {
      expect(rules.contains('<exclude domain="$domain" path="." />'), isTrue,
          reason: 'домен $domain должен быть исключён из облачного бэкапа');
    }
  });

  test('device transfer (Android 12+) excludes every storage domain', () {
    final rules = read(extractionPath);
    final covered = rules.contains('<cloud-backup>') &&
        rules.contains('<device-transfer>');
    expect(covered, isTrue,
        reason: 'обе секции data-extraction-rules должны ограничивать перенос');
    for (final domain in [
      'root',
      'file',
      'database',
      'sharedpref',
      'external',
    ]) {
      expect(rules.contains('<exclude domain="$domain" path="." />'), isTrue,
          reason: 'домен $domain должен быть исключён из переноса устройств');
    }
  });
}
