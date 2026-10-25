import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  test('iOS signs the APNs entitlement in all Runner configurations', () {
    final document = XmlDocument.parse(
      File('ios/Runner/Runner.entitlements').readAsStringSync(),
    );
    expect(
      document.findAllElements('key').map((n) => n.innerText),
      contains('aps-environment'),
    );
    final project = File('ios/Runner.xcodeproj/project.pbxproj')
        .readAsStringSync();
    expect(
      RegExp('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;')
          .allMatches(project)
          .length,
      3,
    );
  });
  test('iOS plugins have permission macros and CocoaPods configurations', () {
    final podfile = File('ios/Podfile').readAsStringSync();
    expect(podfile, contains('flutter_additional_ios_build_settings'));
    for (final permission in [
      'MICROPHONE',
      'PHOTOS',
      'LOCATION',
      'NOTIFICATIONS',
    ]) {
      expect(podfile, contains('PERMISSION_$permission=1'));
    }
    expect(
      File('ios/Flutter/Debug.xcconfig').readAsStringSync(),
      contains('Pods-Runner.debug.xcconfig'),
    );
    expect(
      File('ios/Flutter/Release.xcconfig').readAsStringSync(),
      contains('Pods-Runner.release.xcconfig'),
    );
  });
}
