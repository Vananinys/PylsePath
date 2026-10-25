import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'push_service.dart';
import 'background_location_service.dart';

/// Ошибка авторизации с готовым для UI текстом на русском.
class AuthServiceException implements Exception {
  const AuthServiceException(
    this.message, {
    this.isEmailNotConfirmed = false,
    this.createdUserId,
  });

  final String message;

  /// true — аккаунт создан, но требуется подтверждение e-mail.
  final bool isEmailNotConfirmed;

  /// Available after sign-up when email confirmation prevents a session.
  /// Only used to bind the already accepted local receipt on this device.
  final String? createdUserId;

  @override
  String toString() => message;
}

/// Регистрация, вход и выход через Supabase Auth + создание строки в `profiles`.
class AuthService {
  /// Клиент или null, если Supabase не инициализирован (например, в тестах).
  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  static bool get isAvailable => _client != null;

  User? get currentUser => _client?.auth.currentUser;
  Session? get currentSession => _client?.auth.currentSession;
  bool get isSignedIn => currentSession != null;
  String? get userId => currentUser?.id;

  /// Поток изменений сессии: по нему AuthGate переключает экраны.
  Stream<AuthState>? get authStateChanges => _client?.auth.onAuthStateChange;

  /// Регистрация. При успехе создаёт начальную запись в `profiles`
  /// (id = user.id), чтобы у пользователя сразу был профиль.
  Future<User> signUp({required String email, required String password}) async {
    final client = _client;
    if (client == null) {
      throw const AuthServiceException('Supabase не инициализирован');
    }

    try {
      final response = await client.auth
          .signUp(
            email: email.trim(),
            password: password,
            // Куда вернуть пользователя после клика по письму:
            // кастомная схема pulsepath://login-callback вместо Site URL
            // (localhost:3000). Адрес должен быть в allow-list проекта:
            // Supabase → Authentication → URL Configuration → Redirect URLs.
            emailRedirectTo: AppConfig.authRedirectUrl,
          )
          .timeout(const Duration(seconds: 20));

      final user = response.user;
      if (user == null) {
        throw const AuthServiceException(
          'Не удалось создать аккаунт. Попробуйте ещё раз.',
        );
      }

      // Если в проекте включено подтверждение e-mail, сессии ещё нет, а значит
      // RLS не пропустит вставку в profiles (нет auth.uid()) — просим
      // пользователя подтвердить почту и войти.
      if (response.session == null) {
        throw AuthServiceException(
          'Аккаунт создан. Подтвердите e-mail по ссылке из письма и войдите.',
          isEmailNotConfirmed: true,
          createdUserId: user.id,
        );
      }

      // Профиль создаём «мягко»: аккаунт уже существует, и валить регистрацию
      // из-за строки в profiles нельзя — она появится при первом сохранении
      // профиля или при следующем входе (_ensureProfileExists).
      try {
        await _createInitialProfile(user);
      } catch (error) {
        debugPrint(
          '[AuthService] Не удалось создать стартовый профиль: $error',
        );
      }
      return user;
    } on AuthServiceException {
      rethrow;
    } on AuthException catch (error) {
      throw AuthServiceException(humanizeAuthError(error));
    } on PostgrestException catch (error) {
      throw AuthServiceException('Ошибка базы данных: ${error.message}');
    } catch (error) {
      debugPrint('[AuthService] signUp failed: $error');
      throw const AuthServiceException(
        'Нет связи с сервером. Проверьте интернет и попробуйте снова.',
      );
    }
  }

  /// Вход по e-mail и паролю.
  Future<User> signIn({required String email, required String password}) async {
    final client = _client;
    if (client == null) {
      throw const AuthServiceException('Supabase не инициализирован');
    }

    try {
      final response = await client.auth
          .signInWithPassword(email: email.trim(), password: password)
          .timeout(const Duration(seconds: 20));

      final user = response.user;
      if (user == null) {
        throw const AuthServiceException(
          'Не удалось войти. Проверьте e-mail и пароль.',
        );
      }

      // Если профиля в облаке ещё нет (например, регистрация шла с
      // подтверждением e-mail) — создаём его при первом же входе.
      await _ensureProfileExists(user);
      return user;
    } on AuthServiceException {
      rethrow;
    } on AuthException catch (error) {
      throw AuthServiceException(
        humanizeAuthError(error),
        // По этому флагу экран входа предложит отправить письмо повторно.
        isEmailNotConfirmed: error.code == 'email_not_confirmed',
      );
    } on PostgrestException catch (error) {
      throw AuthServiceException('Ошибка базы данных: ${error.message}');
    } catch (error) {
      debugPrint('[AuthService] signIn failed: $error');
      throw const AuthServiceException(
        'Нет связи с сервером. Проверьте интернет и попробуйте снова.',
      );
    }
  }

  /// Повторная отправка письма для подтверждения e-mail.
  ///
  /// Нужна, если письмо не пришло или ссылка в нём устарела; адрес возврата
  /// тот же — кастомная схема приложения.
  Future<void> resendConfirmationEmail({required String email}) async {
    final client = _client;
    if (client == null) {
      throw const AuthServiceException('Supabase не инициализирован');
    }

    try {
      await client.auth
          .resend(
            type: OtpType.signup,
            email: email.trim(),
            emailRedirectTo: AppConfig.authRedirectUrl,
          )
          .timeout(const Duration(seconds: 15));
    } on AuthException catch (error) {
      throw AuthServiceException(humanizeAuthError(error));
    } catch (error) {
      debugPrint('[AuthService] resend failed: $error');
      throw const AuthServiceException(
        'Не удалось отправить письмо. Проверьте интернет и попробуйте снова.',
      );
    }
  }

  /// Отправляет письмо для смены пароля.
  ///
  /// Ссылка возвращает в приложение на форму нового пароля.
  Future<void> sendPasswordReset({required String email}) async {
    final client = _client;
    if (client == null) {
      throw const AuthServiceException('Supabase не инициализирован');
    }

    try {
      await client.auth
          .resetPasswordForEmail(
            email.trim(),
            redirectTo: AppConfig.authRedirectUrl,
          )
          .timeout(const Duration(seconds: 15));
    } on AuthException catch (error) {
      throw AuthServiceException(humanizeAuthError(error));
    } catch (error) {
      debugPrint('[AuthService] resetPassword failed: $error');
      throw const AuthServiceException(
        'Не удалось отправить письмо. Проверьте интернет и попробуйте снова.',
      );
    }
  }

  Future<void> updatePassword(String password) async {
    final client = _client;
    if (client == null || currentSession == null) {
      throw const AuthServiceException(
        'Ссылка устарела. Запросите новое письмо.',
      );
    }
    try {
      await client.auth
          .updateUser(UserAttributes(password: password))
          .timeout(const Duration(seconds: 20));
    } on AuthException catch (error) {
      throw AuthServiceException(humanizeAuthError(error));
    } catch (_) {
      throw const AuthServiceException(
        'Не удалось сохранить пароль. Проверьте интернет.',
      );
    }
  }

  /// Выход из аккаунта (локальная сессия очищается, AuthGate вернёт логин).
  Future<void> signOut() async {
    final client = _client;
    if (client == null) return;
    try {
      await BackgroundLocationService.instance.setEnabled(false);
      await PushService.instance.unregisterCurrentDevice();
      await client.auth.signOut().timeout(const Duration(seconds: 15));
    } on AuthException catch (error) {
      throw AuthServiceException(humanizeAuthError(error));
    } catch (error) {
      debugPrint('[AuthService] signOut failed: $error');
      throw const AuthServiceException(
        'Не удалось безопасно выйти: проверьте сеть и настройку push RPC',
      );
    } finally {
      PushService.instance.finishSignOut();
    }
  }

  /// Гарантирует наличие строки профиля в облаке (id = user.id).
  /// Ошибки не пробрасываем: вход важнее, профиль догонит при сохранении.
  Future<void> _ensureProfileExists(User user) async {
    final client = _client;
    if (client == null) return;

    try {
      final existing = await client
          .from(AppConfig.profilesTable)
          .select('id')
          .eq('id', user.id)
          .maybeSingle()
          .timeout(const Duration(seconds: 12));
      if (existing == null) {
        await _createInitialProfile(user);
      }
    } catch (error) {
      debugPrint('[AuthService] Не удалось проверить профиль: $error');
    }
  }

  /// Начальная строка в `profiles`. Значения совпадают с локальными
  /// дефолтами UserProfileRepository (70 кг / 175 см / 30 лет).
  ///
  /// Колонки сверены с реальной таблицей: weight/height (не weight_kg/height_cm),
  /// username, age, updated_at. Поля avatar_url здесь нет — аватара ещё нет.
  Future<void> _createInitialProfile(User user) async {
    final client = _client;
    if (client == null) return;

    await client
        .from(AppConfig.profilesTable)
        .upsert(<String, dynamic>{
          'id': user.id,
          'username': _defaultUsername(user),
          'weight': 70,
          'height': 175,
          'age': 30,
          'show_weight': false,
          'show_age': false,
          'show_gender': false,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'id')
        .timeout(const Duration(seconds: 15));
  }

  static String _defaultUsername(User user) {
    final metadataName = user.userMetadata?['username'];
    if (metadataName is String && metadataName.trim().isNotEmpty) {
      return metadataName.trim();
    }
    // Запасной вариант: часть e-mail до @.
    final email = user.email;
    if (email != null && email.contains('@')) {
      return email.split('@').first;
    }
    return 'Райдер';
  }

  /// Переводит ошибки Supabase Auth на русский.
  static String humanizeAuthError(AuthException error) {
    // Отдельно: сетевые сбои приходят как AuthRetryableFetchException.
    if (error is AuthRetryableFetchException) {
      return 'Нет связи с сервером Supabase. Проверьте интернет.';
    }

    switch (error.code) {
      case 'invalid_credentials':
      case 'invalid_grant':
        return 'Неверный e-mail или пароль';
      case 'email_exists':
      case 'user_already_exists':
        return 'Аккаунт с таким e-mail уже зарегистрирован';
      case 'weak_password':
        return 'Слишком простой пароль: нужно минимум 6 символов';
      case 'email_not_confirmed':
        return 'E-mail не подтверждён. Перейдите по ссылке из письма.';
      case 'user_not_found':
        return 'Пользователь с таким e-mail не найден';
      case 'over_email_send_rate_limit':
      case 'over_request_rate_limit':
        return 'Слишком много попыток. Попробуйте позже.';
      case 'signup_disabled':
        return 'Регистрация отключена в настройках проекта';
      case 'validation_failed':
        return 'Проверьте формат e-mail и длину пароля';
      case 'same_password':
        return 'Новый пароль совпадает со старым';
      default:
        return error.message.isEmpty
            ? 'Не удалось выполнить вход. Попробуйте ещё раз.'
            : 'Ошибка авторизации: ${error.message}';
    }
  }
}
