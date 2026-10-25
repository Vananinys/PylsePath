// Тесты маппинга ошибок авторизации на русский и преобразования профиля
// в строку таблицы `profiles` (имена колонок сверены с реальным проектом).
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pulsepath/models/user_profile.dart';
import 'package:pulsepath/services/auth_service.dart';
import 'package:pulsepath/services/profile_sync_service.dart';

UserProfile _profile({
  double weight = 75.5,
  double height = 175,
  int age = 30,
  String username = 'Райдер',
  String? photoPath,
}) {
  return UserProfile(
    weightKg: weight,
    heightCm: height,
    age: age,
    username: username,
    photoPath: photoPath,
  );
}

void main() {
  group('AuthService.humanizeAuthError', () {
    String humanize(String code, [String message = 'raw']) =>
        AuthService.humanizeAuthError(AuthException(message, code: code));

    test('неверный пароль', () {
      expect(humanize('invalid_credentials'), 'Неверный e-mail или пароль');
      expect(humanize('invalid_grant'), 'Неверный e-mail или пароль');
    });

    test('e-mail уже занят', () {
      expect(
        humanize('email_exists'),
        'Аккаунт с таким e-mail уже зарегистрирован',
      );
      expect(
        humanize('user_already_exists'),
        'Аккаунт с таким e-mail уже зарегистрирован',
      );
    });

    test('слабый пароль', () {
      expect(humanize('weak_password'), contains('минимум 6 символов'));
    });

    test('e-mail не подтверждён', () {
      expect(
        humanize('email_not_confirmed'),
        contains('E-mail не подтверждён'),
      );
    });

    test('пользователь не найден', () {
      expect(
        humanize('user_not_found'),
        'Пользователь с таким e-mail не найден',
      );
    });

    test('слишком много попыток', () {
      expect(
        humanize('over_email_send_rate_limit'),
        contains('Слишком много попыток'),
      );
      expect(
        humanize('over_request_rate_limit'),
        contains('Слишком много попыток'),
      );
    });

    test('регистрация отключена', () {
      expect(humanize('signup_disabled'), contains('Регистрация отключена'));
    });

    test('неизвестный код — показываем исходный текст', () {
      expect(
        humanize('weird_code', 'Something broke'),
        contains('Something broke'),
      );
    });

    test('пустое сообщение — общий текст без «Ошибка авторизации:»', () {
      expect(
        AuthService.humanizeAuthError(const AuthException('')),
        'Не удалось выполнить вход. Попробуйте ещё раз.',
      );
    });
  });

  group('ProfileSyncService.toRow — колонки таблицы profiles', () {
    test('id/username/weight/height/age/updated_at', () {
      final row = ProfileSyncService.toRow(
        profile: _profile(),
        userId: 'user-1',
      );

      expect(row['id'], 'user-1');
      expect(row['username'], 'Райдер');
      expect(row['weight'], 75.5);
      expect(row['height'], 175);
      expect(row['age'], 30);
      expect(row['updated_at'], isA<String>());
    });

    test('целые значения уходят как int (колонка может быть integer)', () {
      final row = ProfileSyncService.toRow(
        profile: _profile(weight: 70, height: 180),
        userId: 'u',
      );
      expect(row['weight'], isA<int>());
      expect(row['height'], isA<int>());
    });

    test('нет колонок, которых нет в таблице', () {
      final row = ProfileSyncService.toRow(profile: _profile(), userId: 'u');
      for (final absent in <String>[
        'weight_kg',
        'height_cm',
        'email',
        'photo_path',
        'avatar_index',
        'created_at',
      ]) {
        expect(
          row.containsKey(absent),
          isFalse,
          reason: 'колонки $absent нет в profiles',
        );
      }
    });

    test('status/city/preferred_riding_type пишутся по новой схеме', () {
      final row = ProfileSyncService.toRow(profile: _profile(), userId: 'u');
      // Статус и город — непустые строки, тип катания — именем enum'а.
      expect(row['status'], isA<String>());
      expect((row['status'] as String).isNotEmpty, isTrue);
      expect(row['city'], isA<String>());
      expect(
        RidingType.values.map((t) => t.name),
        contains(row['preferred_riding_type']),
      );
    });

    test('значения обрезаются по физическим границам', () {
      final row = ProfileSyncService.toRow(
        profile: _profile(weight: 148852, height: 1488, age: 1488),
        userId: 'u',
      );
      expect(row['weight'], 250);
      expect(row['height'], 230);
      expect(row['age'], 120);
    });

    test('avatar_url пишется только для настоящей ссылки', () {
      final localPath = ProfileSyncService.toRow(
        profile: _profile(
          photoPath: '/data/user/0/app/profile_photos/avatar_1.jpg',
        ),
        userId: 'u',
      );
      // Локальный путь в URL-колонку не отправляем, чтобы не портить значение.
      expect(localPath.containsKey('avatar_url'), isFalse);

      const url = 'https://cdn.example.com/avatar.jpg';
      final remote = ProfileSyncService.toRow(
        profile: _profile(photoPath: url),
        userId: 'u',
      );
      expect(remote['avatar_url'], url);
    });

    test('пустой username заменяется на «Райдер»', () {
      final row = ProfileSyncService.toRow(
        profile: _profile(username: '   '),
        userId: 'u',
      );
      expect(row['username'], 'Райдер');
    });

    test('updated_at — UTC в ISO-8601', () {
      final row = ProfileSyncService.toRow(
        profile: _profile(),
        userId: 'u',
        now: DateTime.utc(2026, 5, 4, 9, 15),
      );
      expect(row['updated_at'], '2026-05-04T09:15:00.000Z');
    });
  });
}
