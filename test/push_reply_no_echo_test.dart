import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/services/push_service.dart';

void main() {
  test(
    'failed notification action body never echoes unsent reply input',
    () {
      const secret = 'СЕКРЕТНЫЙ-ТЕКСТ-ОТВЕТА-НЕ-ПОКИДАЕТ-ЧАТ';
      for (final replySent in [false, true]) {
        final body = PushService.failedActionBody(
          replySent: replySent,
          input: secret,
        );
        expect(
          body.contains(secret),
          isFalse,
          reason:
              'Неправленный текст ответа не должен появляться в системном '
              'уведомлении: шторку и историю читают сторонние '
              'NotificationListener-приложения.',
        );
        expect(body, isNotEmpty);
      }
      expect(
        PushService.failedActionBody(replySent: false, input: null),
        PushService.failedActionBody(replySent: true, input: 'любой текст'),
      );
    },
  );

  test('push_service.dart does not echo reply input into notifications', () {
    final source = File('lib/services/push_service.dart').readAsStringSync();
    expect(
      source.contains('Неотправленный ответ'),
      isFalse,
      reason: 'Регрессионная защита: эхо неотправленного ответа удалено '
          'из уведомления о неудаче действия (push_service.dart).',
    );
  });
}
