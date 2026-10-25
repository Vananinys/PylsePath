# PulsePath — структура проекта (контекст для ИИ)

Flutter-приложение (Android/iOS/Web): навигатор для активных поездок (велосипед/самокат/пешком) на карте CartoDB Positron (flutter_map), с трекингом поездок, соцсетью, гаражом транспорта, достижениями и офлайн-картами.
Бэкенды: Supabase (auth, БД profiles/rides, storage аватаров), Firebase (FCM push), OSRM (маршруты), Overpass (POI), Open-Meteo-подобный weather API, Cloudflare-туннель к локальному серверу маршрутов.

- Стек: Flutter >=3.44, Dart >=3.13, provider для состояния
- Ключевые пакеты: flutter_map 7, flutter_map_tile_caching 9, geolocator, flutter_compass, supabase_flutter, firebase_messaging, flutter_local_notifications, record (аудио), audioplayers, share_plus, image_picker, xml (GPX)
- Точка входа: `lib/main.dart` (1106 строк — корневой виджет, карта, роутинг экранов)
- Конфиг/секреты: `lib/config.dart` — URL Supabase/OSRM/туннеля через `--dart-define` с дефолтами

## Дерево (только значимый код; .dart_tool, .gradle, .idea, .widget_preview — служебные)

```
lib/
  main.dart                      # Корневой виджет: карта на весь экран, меню, навигация по экранам, init Supabase/Firebase
  config.dart                    # Константы: OSRM URLs, offline tile URL, baseUrl туннеля, Supabase URL/key (dart-define)

  controllers/
    map_navigation_controller.dart  # [1313 строк] Ядро: GPS, маршрутизация, стоп/старт поездки, камера карты, состояние навигации

  src/map_screen/                # Миксины, разбивающие main.dart по зонам ответственности
    camera_compass_mixin.dart    # Ориентация камеры по компасу
    chat_push_mixin.dart         # Push-уведомления чатов
    drawer_mixin.dart            # Боковое меню (drawer)
    markers_mixin.dart           # Маркеры на карте
    ride_sheets_mixin.dart       # Bottom sheets во время поездки
    route_actions_mixin.dart     # Действия с маршрутом (старт/сохранение/ GPX)
    urban_map_mixin.dart         # Слои/стили городской карты

  models/                        # Чистые data-классы (без логики)
    activity_type.dart  transport_type.dart  vehicle.dart     # Типы активности/транспорта
    camera_lock_mode.dart  map_mark.dart  surface_info.dart   # Карта: режимы камеры, метки, покрытие
    chat_message.dart    # Сообщения чатов
    community_post.dart  post_comment.dart                   # Посты сообщества + комментарии
    friend_profile.dart  user_profile.dart                   # Профили
    progress_period.dart                                     # Периоды целей/прогресса
    route_step.dart  saved_route.dart                        # Шаги маршрута, сохранённые маршруты
    workout_record.dart                                      # Запись о поездке

  data/                          # Репозитории поверх Supabase/SharedPreferences
    app_settings.dart            # Настройки приложения (SharedPreferences)
    user_scope.dart              # Изоляция данных по пользователю
    user_profile_repository.dart # CRUD профиля (Supabase)
    saved_routes_repository.dart # Сохранённые маршруты
    workout_history_repository.dart  # История поездок
    progress_goals_repository.dart   # Цели прогресса
    ui_modules.dart              # Включение/выключение модулей UI

  services/                      # Внешние интеграции и бизнес-логика (stateless-сервисы)
    auth_service.dart            # Supabase auth (вход/регистрация/выход)
    profile_sync_service.dart    # Синхронизация профиля с Supabase
    profile_photo_service.dart   # Загрузка/хранение фото профиля
    push_service.dart            # FCM токены, подписки
    notification_service.dart    # Локальные уведомления
    notification_permission_service.dart
    chat_service.dart            # Чаты (Supabase realtime)
    friend_service.dart          # Друзья: заявки, поиск
    community_service.dart       # Лента сообщества, посты, лайки, комментарии
    group_ride_service.dart      # Групповые поездки
    garage_service.dart          # Транспорт пользователя (гараж)
    rides_service.dart           # Запись/загрузка поездок
    achievements_service.dart    # Достижения
    goals_service.dart           # Цели
    routing_service.dart         # Построение маршрута (OSRM/туннель)
    geocoding_service.dart       # Геокодирование (поиск адресов)
    overpass_service.dart        # POI из OpenStreetMap (Overpass API)
    weather_service.dart         # Погода
    compass_service.dart         # Компас
    offline_maps_service.dart    # Кэш тайлов для офлайна (flutter_map_tile_caching)
    map_marks_service.dart       # Метки на карте

  state/
    profile_provider.dart        # ChangeNotifier профиля (provider)

  screens/                       # Полноэкранные UI-страницы
    auth_gate.dart               # Маршрутизация авторизован/нет
    login_screen.dart  register_screen.dart  onboarding_screen.dart
    profile_screen.dart          # [1400 строк] Профиль: аватар, статистика, прогресс
    public_profile_screen.dart   # Чужой профиль
    friends_screen.dart          # Друзья
    chats_list_screen.dart  chat_screen.dart  # Список чатов и переписка
    notifications_screen.dart    # Уведомления
    community-связанные: post_comments_screen.dart
    garage_screen.dart           # Гараж транспорта
    group_ride_screen.dart       # Групповая поездка
    saved_routes_screen.dart     # Сохранённые маршруты
    workout_history_screen.dart  workout_detail_screen.dart  # История и детали поездок
    ride_heatmap_screen.dart     # Тепловая карта поездок
    achievements_screen.dart     # Достижения
    offline_maps_screen.dart     # Управление офлайн-картами
    settings_screen.dart  about_screen.dart
    training_center_screen.dart   # Календарь, недельные итоги и динамика тренировок

  widgets/                       # Переиспользуемые UI-компоненты
    pre_ride_widget.dart         # Панель предстартовой подготовки
    route_details_bottom_sheet.dart  workout_stats_bottom_sheet.dart  # Bottom sheets
    vehicle_selector_sheet.dart  activity_chip.dart  surface_legend.dart  # Выбор транспорта/активности, легенда покрытия
    map_ui_overlays.dart         # Оверлеи поверх карты
    rider_marker.dart  user_location_marker.dart  triangle_clipper.dart  # Маркеры на карте
    friend_map_panel.dart        # Панель друзей на карте
    community_feed.dart  community_post_card.dart            # Лента сообщества
    auth_header.dart             # Шапка экранов входа

  utils/
    geo_utils.dart               # Расчёты расстояний и пр.
    gpx_utils.dart               # Экспорт/импорт GPX
    ride_id.dart                 # Генерация ID поездок
    notification_identity.dart   # Уникальные ID уведомлений
    file_reader.dart / _io.dart / _web.dart   # Условный импорт чтения файлов (web/mobile)

android/                         # Платформа Android
  app/src/main/kotlin/com/example/pulsepath/MainActivity.kt
  app/src/main/AndroidManifest.xml  # Разрешения: гео (в т.ч. фон), уведомления, микрофон (record), интернет

test/                            # Тесты (flutter test)
  auth_service_test.dart         # Авторизация
  sync_services_test.dart        # Синхронизация
  deep_link_config_test.dart  notification_config_test.dart
  profile_gesture_test.dart  profile_progress_test.dart  progress_period_test.dart
  ui_modules_test.dart  widget_test.dart

README.md / README_MERGED_RU.md  # Документация
docs/merge/                      # Материалы по слиянию проектов
```

## Ключевые связи (для точных промтов)
- Карта и поездка: `main.dart` + `controllers/map_navigation_controller.dart` + `src/map_screen/*` — единая зона; менять навигацию/трекинг нужно в контроллере, UI-элементы — в `widgets/map_ui_overlays.dart` и `ride_sheets_mixin.dart`.
- Данные пользователя: экран → `services/*_service.dart` (логика) → `data/*_repository.dart` (Supabase/SharedPreferences) → `models/*` (типы).
- Состояние профиля глобально: `state/profile_provider.dart` (provider), доступ через `context.watch<ProfileProvider>()`.
- Маршруты: `routing_service.dart` → endpoint `config.routeUrl` (OSRM-совместимый через Cloudflare-туннель); GPX — `utils/gpx_utils.dart`.
- Push: FCM (`push_service.dart`) + локальные (`notification_service.dart`, `utils/notification_identity.dart`); Android-манифест уже содержит разрешения.
- Веб-специфика (file_reader) — только в `utils/file_reader*.dart`, условный импорт.

## Команды
- Запуск: `flutter run --dart-define=OSRM_BIKE_URL=... --dart-define=SUPABASE_URL=...`
- Тесты: `flutter test`
- Анализ: `flutter analyze`
