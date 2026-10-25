import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../models/user_profile.dart';
import '../utils/file_reader.dart';

/// Ошибка синхронизации профиля с готовым для UI текстом.
class ProfileSyncException implements Exception {
  const ProfileSyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Синхронизация профиля райдера с таблицей `profiles` в Supabase.
///
/// Колонки сверены с реальным проектом (PostgREST отдаёт имена в ошибках):
///   id, username, weight, height, age, avatar_url, updated_at, status,
///   city, preferred_riding_type, gender, show_weight, show_age, show_gender
/// (последние семь добавлены миграцией `01_FULL_SCHEMA_FIXED.sql`).
///
/// Ошибки синхронизации никогда не пробрасываются в UI: локальное сохранение
/// важнее, облако догонит при следующем сохранении. Неудача возвращает false.
///
/// Колонки [ProfileSyncService._optionalColumns] появились миграцией
/// `supabase/sql/04_STAGE0_PRESETS.sql`. Если на сервере применена только
/// базовая схема (без неё), PostgREST отвечает PGRST204 «column not found» —
/// тогда запрос автоматически повторяется без этих колонок, чтобы
/// сохранение и чтение профиля не ломались целиком.
class ProfileSyncService {
  /// Колонки, без которых базовая схема профиля остаётся рабочей.
  static const List<String> _optionalColumns = ['ui_preset', 'modules_enabled'];

  /// Код ошибки PostgREST: колонки нет в схеме на сервере.
  static const String _columnNotFoundCode = 'PGRST204';

  /// Столбец из сообщения об ошибке, которого нет на сервере (или null).
  static String? _missingColumnFrom(PostgrestException error) {
    if (error.code != _columnNotFoundCode) return null;
    for (final column in _optionalColumns) {
      if (error.message.contains(column)) return column;
    }
    return null;
  }

  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      // Supabase не инициализирован (тесты/офлайн-сборка) — синхронизировать нечего.
      return null;
    }
  }

  static bool get isAvailable => _client != null;

  /// Строка для UPSERT. Публичная и чистая — её удобно проверять тестами.
  ///
  /// [skipOptionalColumns] = true — строка без колонок из [_optionalColumns]
  /// (после ошибки PGRST204: на сервере ещё нет миграции пресетов).
  static Map<String, dynamic> toRow({
    required UserProfile profile,
    required String userId,
    DateTime? now,
    bool skipOptionalColumns = false,
    bool clearAvatar = false,
  }) {
    // avatar_url — это URL в Storage. Источник: сначала отдельное поле
    // avatarUrl, затем — для старых записей — photoPath, если там лежит
    // http-ссылка. Локальный путь к файлу в URL-колонку не пишем, чтобы не
    // портить значение в облаке.
    final avatarUrl = _isHttpUrl(profile.avatarUrl)
        ? profile.avatarUrl
        : (_isHttpUrl(profile.photoPath) ? profile.photoPath : null);
    return <String, dynamic>{
      'id': userId,
      'username': profile.username.trim().isEmpty
          ? 'Райдер'
          : profile.username.trim(),
      // Границы те же, что в форме профиля (20..250 кг, 100..230 см, 5..120 лет).
      'weight': _num(UserProfile.clampWeight(profile.weightKg)),
      'height': _num(UserProfile.clampHeight(profile.heightCm)),
      'age': UserProfile.clampAge(profile.age),
      'updated_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
      // Тип катания храним именем enum'а (стабильнее лейбла при локализации).
      'status': profile.status.trim().isEmpty ? null : profile.status.trim(),
      'city': profile.city.trim().isEmpty ? null : profile.city.trim(),
      'preferred_riding_type': profile.preferredRidingType.name,
      'gender': profile.gender,
      // Приватность: что показывать другим (публичная проекция отдаст
      // скрытые поля как null).
      'show_weight': profile.showWeight,
      'show_age': profile.showAge,
      'show_gender': profile.showGender,
      // Настраиваемость интерфейса (Этап 0). null-значения не пишем,
      // чтобы не затирать облачные значения при частичных сохранениях.
      if (!skipOptionalColumns && profile.uiPreset != null)
        'ui_preset': profile.uiPreset,
      if (!skipOptionalColumns && profile.modulesEnabled != null)
        'modules_enabled': profile.modulesEnabled!.toList(),
      if (clearAvatar || avatarUrl != null) 'avatar_url': avatarUrl,
    };
  }

  /// Значения профиля из строки `profiles` (для загрузки в локальную модель).
  /// Публичная и чистая — проверяется тестами.
  static Map<String, Object?> profileFieldsFromRow(Map<String, dynamic> row) {
    return <String, Object?>{
      'username': row['username'] as String?,
      'weight': _toDoubleOrNull(row['weight']),
      'height': _toDoubleOrNull(row['height']),
      'age': _toIntOrNull(row['age']),
      'avatarUrl': row['avatar_url'] as String?,
      'status': row['status'] as String?,
      'city': row['city'] as String?,
      // preferred_riding_type хранится именем [RidingType]; неизвестное
      // значение (или null) → null — локальное значение остаётся как было.
      'preferredRidingType': _ridingTypeFromRow(row['preferred_riding_type']),
      'gender': row['gender'] as String?,
      'showWeight': row['show_weight'] as bool?,
      'showAge': row['show_age'] as bool?,
      'showGender': row['show_gender'] as bool?,
      'uiPreset': row['ui_preset'] as String?,
      'modulesEnabled': (row['modules_enabled'] as List<dynamic>?)
          ?.map((item) => item as String)
          .toSet(),
    };
  }

  static RidingType? _ridingTypeFromRow(Object? value) {
    final name = value?.toString();
    if (name == null || name.isEmpty) return null;
    for (final type in RidingType.values) {
      if (type.name == name) return type;
    }
    return null;
  }

  /// Читает профиль текущего пользователя (по auth.uid()).
  /// Возвращает null, если строки нет, нет сессии или произошла ошибка.
  Future<Map<String, Object?>?> fetchProfile() async {
    final client = _client;
    if (client == null) return null;

    final userId = client.auth.currentUser?.id;
    if (userId == null) return null;

    const fullSelect =
        'username, weight, height, age, avatar_url, status, city, '
        'preferred_riding_type, gender, show_weight, show_age, '
        'show_gender, ui_preset, modules_enabled';
    // Базовая схема без миграции пресетов: тот же список без опциональных
    // колонок — profileFieldsFromRow вернёт по ним null и локальные
    // значения сохранятся.
    const fallbackSelect =
        'username, weight, height, age, avatar_url, status, city, '
        'preferred_riding_type, gender, show_weight, show_age, show_gender';

    Future<List<Map<String, dynamic>>> selectRow(String columns) => client
        .from(AppConfig.profilesTable)
        .select(columns)
        .eq('id', userId)
        .maybeSingle()
        .then(
          (row) => row == null
              ? const <Map<String, dynamic>>[]
              : <Map<String, dynamic>>[Map<String, dynamic>.from(row)],
        );

    try {
      List<Map<String, dynamic>> rows;
      try {
        rows = await selectRow(fullSelect).timeout(const Duration(seconds: 8));
      } on PostgrestException catch (error) {
        // Повторяем без опциональных колонок, только если причина — их
        // отсутствие на сервере; прочие ошибки PostgREST не глотаем.
        if (_missingColumnFrom(error) == null) rethrow;
        rows = await selectRow(fallbackSelect)
            .timeout(const Duration(seconds: 8));
      }
      if (rows.isEmpty) return null;
      return profileFieldsFromRow(rows.first);
    } on PostgrestException catch (error) {
      debugPrint(
        '[ProfileSync] Не удалось прочитать профиль: ${error.code} ${error.message}',
      );
      return null;
    } catch (error) {
      debugPrint('[ProfileSync] Не удалось прочитать профиль: $error');
      return null;
    }
  }

  /// Загружает фото в бакет `avatars` и возвращает публичный URL.
  ///
  /// Бросает [ProfileSyncException] с понятным текстом: без созданного
  /// публичного бакета и политик Storage загрузка невозможна.
  Future<String> uploadAvatar(String localFilePath) async {
    final client = _client;
    if (client == null) {
      throw const ProfileSyncException('Supabase не инициализирован');
    }

    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw const ProfileSyncException(
        'Войдите в аккаунт, чтобы сохранить фото в облако',
      );
    }

    try {
      // File(path) на мобильных, XFile(path) на web — через общий ридер.
      final bytes = await readBytesFromPath(localFilePath);
      // Уникальное имя на пользователя — так проще писать политики Storage:
      // (storage.foldername(name))[1] = auth.uid()::text.
      final objectPath =
          '$userId/avatar_${DateTime.now().millisecondsSinceEpoch}'
          '${_extensionOf(localFilePath)}';

      await client.storage
          .from(AppConfig.avatarsBucket)
          .uploadBinary(
            objectPath,
            bytes,
            fileOptions: const FileOptions(upsert: true, cacheControl: '3600'),
          );

      final url = client.storage
          .from(AppConfig.avatarsBucket)
          .getPublicUrl(objectPath);
      debugPrint('[ProfileSync] Аватар загружен: $url');
      return url;
    } on StorageException catch (error) {
      debugPrint('[ProfileSync] Storage ${error.statusCode}: ${error.message}');
      throw ProfileSyncException(_humanizeStorageError(error));
    } on ProfileSyncException {
      rethrow;
    } on FileReadException catch (error) {
      throw ProfileSyncException(error.message);
    } catch (error) {
      debugPrint('[ProfileSync] Не удалось загрузить аватар: $error');
      throw const ProfileSyncException(
        'Не удалось загрузить фото. Проверьте интернет.',
      );
    }
  }

  /// Загружает фото баннера в папку пользователя бакета `avatars` и
  /// возвращает путь объекта (URL строится публичным профилем при чтении).
  Future<String> uploadProfileCover(String localFilePath) async {
    final client = _client;
    if (client == null) {
      throw const ProfileSyncException('Supabase не инициализирован');
    }
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw const ProfileSyncException(
        'Войдите в аккаунт, чтобы сохранить фото баннера',
      );
    }

    try {
      final bytes = await readBytesFromPath(localFilePath);
      if (bytes.length > 8 * 1024 * 1024) {
        throw const ProfileSyncException(
          'Фото слишком большое. Выберите изображение до 8 МБ.',
        );
      }
      final objectPath =
          '$userId/cover_${DateTime.now().millisecondsSinceEpoch}'
          '${_extensionOf(localFilePath)}';
      await client.storage
          .from(AppConfig.avatarsBucket)
          .uploadBinary(
            objectPath,
            bytes,
            fileOptions: const FileOptions(cacheControl: '3600', upsert: false),
          );
      return objectPath;
    } on StorageException catch (error) {
      debugPrint('[ProfileSync] Не удалось загрузить баннер: ${error.message}');
      throw ProfileSyncException(_humanizeStorageError(error));
    } on ProfileSyncException {
      rethrow;
    } on FileReadException catch (error) {
      throw ProfileSyncException(error.message);
    } catch (error) {
      debugPrint('[ProfileSync] Не удалось загрузить баннер: $error');
      throw const ProfileSyncException(
        'Не удалось загрузить фото баннера. Проверьте интернет.',
      );
    }
  }

  static String _humanizeStorageError(StorageException error) {
    final message = error.message.toLowerCase();
    if (error.statusCode == '404' || message.contains('bucket not found')) {
      return 'Бакет «${AppConfig.avatarsBucket}» не найден в Supabase Storage. '
          'Создайте его (Public) и добавьте политики доступа.';
    }
    if (error.statusCode == '403' || message.contains('policy')) {
      return 'Нет прав на загрузку в Storage. Проверьте политики бакета '
          '«${AppConfig.avatarsBucket}».';
    }
    return 'Не удалось загрузить фото: ${error.message}';
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    if (dot <= slash || dot == path.length - 1) return '.jpg';
    final extension = path.substring(dot).toLowerCase();
    return extension.length <= 6 ? extension : '.jpg';
  }

  static double? _toDoubleOrNull(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static int? _toIntOrNull(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Отправляет UPSERT профиля текущего пользователя.
  /// Возвращает true, если запись ушла в Supabase.
  Future<bool> upsertProfile(
    UserProfile profile, {
    bool clearAvatar = false,
  }) async {
    final client = _client;
    if (client == null) {
      debugPrint('[ProfileSync] Supabase недоступен — синхронизация пропущена');
      return false;
    }

    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      debugPrint('[ProfileSync] Нет активной сессии — синхронизация пропущена');
      return false;
    }

    try {
      await client
          .from(AppConfig.profilesTable)
          .upsert(
            toRow(profile: profile, userId: userId, clearAvatar: clearAvatar),
            onConflict: 'id',
          );
      debugPrint('[ProfileSync] Профиль синхронизирован ($userId)');
      return true;
    } on PostgrestException catch (error) {
      // На сервере без миграции 04_STAGE0_PRESETS.sql нет ui_preset /
      // modules_enabled: сохраняем профиль ещё раз без них, иначе
      // пользователь теряет синхронизацию целиком из-за двух колонок.
      if (_missingColumnFrom(error) != null) {
        try {
          await client
              .from(AppConfig.profilesTable)
              .upsert(
                toRow(
                  profile: profile,
                  userId: userId,
                  skipOptionalColumns: true,
                  clearAvatar: clearAvatar,
                ),
                onConflict: 'id',
              );
          debugPrint(
            '[ProfileSync] Профиль синхронизирован без пресетов '
            '(на сервере нет миграции 04_STAGE0_PRESETS.sql)',
          );
          return true;
        } catch (retryError) {
          debugPrint(
            '[ProfileSync] Повтор без пресетов не удался: $retryError',
          );
          return false;
        }
      }
      // Чаще всего: нет строки под RLS, не совпало имя колонки, нет прав.
      debugPrint('[ProfileSync] Postgrest ${error.code}: ${error.message}');
      return false;
    } catch (error) {
      debugPrint('[ProfileSync] Не удалось синхронизировать профиль: $error');
      return false;
    }
  }

  /// Целые значения отправляем как int: колонка в Postgres может быть integer,
  /// а JSON-число 70.0 в integer-колонку не приводится.
  static num _num(double value) =>
      value == value.roundToDouble() ? value.round() : value;

  static bool _isHttpUrl(String? value) =>
      value != null &&
      (value.startsWith('http://') || value.startsWith('https://'));
}
