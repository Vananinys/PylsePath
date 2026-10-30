import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:pulsepath/utils/notification_identity.dart';

const androidNamespace = 'http://schemas.android.com/apk/res/android';

void main() {
  test('notification reply retries are idempotent and account scoped', () {
    final id = notificationReplyId('owner', 'message', 'Ответ');
    expect(notificationReplyId('owner', 'message', 'Ответ'), id);
    expect(notificationReplyId('other', 'message', 'Ответ'), isNot(id));
    expect(notificationReplyId('owner', 'next', 'Ответ'), isNot(id));
    expect(notificationReplyId('owner', 'message', 'Другой ответ'), isNot(id));
    expect(
      id,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });
  test('notification id is stable and scoped to receiver/conversation', () {
    expect(
      chatNotificationId('receiver', 'sender'),
      chatNotificationId('receiver', 'sender'),
    );
    expect(
      chatNotificationId('receiver', 'sender'),
      isNot(chatNotificationId('other', 'sender')),
    );
    expect(
      chatNotificationId('receiver', 'sender'),
      inInclusiveRange(0, 0x7fffffff),
    );
  });
  test('Android FCM uses the foreground channel and monochrome icon', () {
    final document = XmlDocument.parse(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
    );
    final entries = {
      for (final node in document.findAllElements('meta-data'))
        node.getAttribute('name', namespaceUri: androidNamespace): node,
    };
    expect(
      entries['com.google.firebase.messaging.default_notification_channel_id']
          ?.getAttribute('value', namespaceUri: androidNamespace),
      'chat_messages',
    );
    expect(
      entries['com.google.firebase.messaging.default_notification_icon']
          ?.getAttribute('resource', namespaceUri: androidNamespace),
      '@drawable/ic_stat_pulsepath',
    );
    final icon = XmlDocument.parse(
      File('android/app/src/main/res/drawable/ic_stat_pulsepath.xml')
          .readAsStringSync(),
    );
    expect(icon.rootElement.name.local, 'vector');
    expect(
      icon
          .findAllElements('path')
          .first
          .getAttribute('fillColor', namespaceUri: androidNamespace),
      '#FFFFFFFF',
    );
  });
  test('Firebase Android client matches existing applicationId', () {
    final config = jsonDecode(
      File('android/app/google-services.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final identity = RegExp(
      r'applicationId\s*=\s*if \(uiBeta\) "([^"]+)" else "([^"]+)"',
    ).firstMatch(gradle);
    expect(
      identity,
      isNotNull,
      reason: 'Regular and UI beta identities must both be declared',
    );
    final packages = (config['client'] as List).map(
      (client) => client['client_info']['android_client_info']['package_name'],
    );
    expect(packages, containsAll([identity!.group(1), identity.group(2)]));
    expect(identity.group(1), isNot(identity.group(2)));
  });
  test('iOS declares microphone/location usage and remote notifications', () {
    final document = XmlDocument.parse(
      File('ios/Runner/Info.plist').readAsStringSync(),
    );
    final keys = document.findAllElements('key').map((node) => node.innerText);
    expect(
      keys,
      containsAll([
        'NSMicrophoneUsageDescription',
        'NSLocationWhenInUseUsageDescription',
        'NSLocationAlwaysAndWhenInUseUsageDescription',
      ]),
    );
    final modes = document
        .findAllElements('key')
        .firstWhere((node) => node.innerText == 'UIBackgroundModes')
        .nextElementSibling!;
    expect(
      modes.findAllElements('string').map((node) => node.innerText),
      contains('remote-notification'),
    );
  });
}
