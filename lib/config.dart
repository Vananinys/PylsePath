class AppConfig {
  // A separate, correctly built OSRM instance is required for each profile.
  static const osrmCarUrl = String.fromEnvironment(
    'OSRM_CAR_URL',
    defaultValue: 'https://router.project-osrm.org',
  );
  static const osrmBikeUrl = String.fromEnvironment(
    'OSRM_BIKE_URL',
    defaultValue: 'https://routing.openstreetmap.de/routed-bike',
  );
  static const osrmFootUrl = String.fromEnvironment(
    'OSRM_FOOT_URL',
    defaultValue: 'https://routing.openstreetmap.de/routed-foot',
  );
  // Do not bulk-download public OSM tiles. Set a licensed offline provider.
  static const offlineTileUrl = String.fromEnvironment('OFFLINE_TILE_URL');

  // IP-адрес вашего ПК в локальной сети (для физического смартфона)
  static const String baseUrl =
      'https://home-myself-kingdom-midnight.trycloudflare.com';

  // Эндпоинт для построения маршрута
  static const String routeUrl = '$baseUrl/api/v1/route';

  // ── Supabase ─────────────────────────────────────────────────────────────
  // Publishable-ключ публичный по дизайну: доступ к данным ограничивает
  // RLS на стороне проекта. Переопределить при сборке можно так:
  //   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://nhxlpfbiskaqahnkrmtx.supabase.co',
  );

  static const String supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_7mi2ISA31DYr-zRIYPjiXQ_NMuaamiX',
  );

  /// Таблица профилей (колонки: id, username, weight, height, age,
  /// avatar_url, updated_at).
  static const String profilesTable = 'profiles';

  /// Таблица заездов.
  static const String ridesTable = 'rides';

  /// Таблица техники пользователя (колонки: id, user_id, name, transport_type,
  /// weight_kg, wheel_size, total_distance, is_active, photo_url, created_at).
  static const String garageTable = 'garage';

  /// Таблица целей по периодам (колонки: id, user_id, period, goal_km,
  /// updated_at). period принимает значения day|week|month|year.
  static const String goalsTable = 'goals';

  /// Бакет Supabase Storage для фото профиля (должен быть Public,
  /// чтобы getPublicUrl() отдавал рабочую ссылку).
  static const String avatarsBucket = 'avatars';

  /// Бакет Supabase Storage для фото в постах/комментариях сообщества.
  /// Путь объекта: `<uid>/post_<timestamp>.<ext>`.
  static const String communityBucket = 'community';

  /// Бакет Supabase Storage для фото техники. Путь объекта: `<uid>/<vehicle_id>.jpg`.
  static const String vehiclesBucket = 'vehicles';

  // ── Deep link для подтверждения e-mail ───────────────────────────────────
  /// Схема приложения. Должна совпадать с объявленной в
  /// android/app/src/main/AndroidManifest.xml и ios/Runner/Info.plist
  /// (совпадение проверяется тестом deep_link_config_test.dart).
  static const String authScheme = 'pulsepath';

  /// Хост callback-ссылки.
  static const String authCallbackHost = 'login-callback';

  /// Куда Supabase возвращает пользователя после подтверждения e-mail.
  ///
  /// ВАЖНО: этот же адрес нужно добавить в Supabase →
  /// Authentication → URL Configuration → Redirect URLs, иначе Supabase
  /// проигнорирует его и вернёт пользователя на Site URL (localhost:3000).
  static const String authRedirectUrl = '$authScheme://$authCallbackHost';
}
