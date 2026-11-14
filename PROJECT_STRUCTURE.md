# PulsePath — описание и карта функций

Flutter-приложение для карт, маршрутов, записи тренировок и общения. Основные платформы Android/iOS/Web; наличие платформы не означает проверку всех её сценариев. Стек: Dart/Flutter, provider, flutter_map; серверные интеграции — Supabase, Firebase push и OSRM-совместимая маршрутизация. Версии зависимостей смотреть в pubspec.yaml.

Читать вместе с AGENTS.md и docs/PROJECT_STATE_RU.md. Далее открывать только исходники нужного модуля; журнал и весь каталог docs в обязательный контекст не входят.

## Карта функций

| Функция | Где начать изучение |
|---|---|
| Запуск, основная карта, переходы между разделами | `lib/main.dart`, `lib/src/map_screen/`, `lib/controllers/map_navigation_controller.dart` |
| Построение маршрута и следование ему | `lib/screens/route_builder_screen.dart` (остановки, поиск и черновик), `lib/screens/route_geometry_editor_screen.dart` (рисование и точная правка трека), `lib/services/routing_service.dart`, `lib/services/trail_guidance.dart`; рисование жестом — `lib/widgets/route_drawing_layer.dart`, сглаживание — `lib/utils/drawn_route_geometry.dart`, геометрия копии — `lib/models/route_edit_state.dart`. Отдельный флаг `ROUTE_DRAWING_ENABLED` не зависит от UI_BETA. |
| Офлайн-карта и готовность маршрута | `lib/services/offline_maps_service.dart`, `lib/models/offline_route_tiles.dart`, `lib/widgets/offline_route_coverage.dart` |
| Запись, GPS, восстановление тренировки | `lib/controllers/map_navigation_controller.dart`, `lib/services/background_location_service.dart`, `lib/data/workout_draft_store.dart` |
| История и повторная синхронизация | `lib/data/workout_history_repository.dart`, `lib/services/rides_service.dart`, `lib/services/network_recovery_sync.dart` |
| Друзья, геопозиции и следы на карте | `lib/services/friend_service.dart`, `lib/widgets/friend_motion_layer.dart`, `lib/widgets/friend_trails_layer.dart`, `lib/services/owned_trail_style_service.dart`; кэш проекции геометрии — `lib/utils/trail_projection_cache.dart` |
| Профиль, оформление и настройки | `lib/state/profile_provider.dart`, `lib/screens/profile_screen.dart`, `lib/screens/public_profile_screen.dart`, `lib/screens/customization_screen.dart`, `lib/screens/settings_screen.dart` |
| Чаты и вложения | `lib/services/chat_service.dart`, `lib/data/chat_local_store.dart`, `lib/screens/chat_screen.dart` |
| E2EE личного текста и стикеров (UI Beta) | Отдельный `E2EE_MESSAGING=true`; `lib/services/e2ee_identity_service.dart`, `lib/screens/e2ee_keys_screen.dart`, `docs/e2ee_chat_schema.sql`, `tools/chat_push/`. Вложения не подключены; обычная сборка не включает флаг. |
| Signal-движок: локальная проверка (UI Beta) | `E2EE_SIGNAL_TEST=true`; `lib/screens/signal_test_screen.dart`, `lib/services/signal_diagnostic.dart`, `lib/services/signal_message_engine.dart`, `lib/data/signal_protocol_stores.dart`, `lib/data/signal_state_database.dart`, `lib/data/signal_isolate_mutex.dart`; Android QA: `tools/signal_android_qa/`. Только синтетические сообщения; реальная переписка пока v1. |
| Локальный тест шифрования (эксперимент UI Beta) | `lib/screens/e2ee_test_chat_screen.dart`, `lib/services/e2ee_box_codec.dart`, `lib/data/e2ee_secret_store.dart`, `lib/data/e2ee_recovery_vault.dart`; только при `UI_BETA=true` и отдельном `E2EE_TEST_CHAT=true`. Не шифрует обычные чаты. |
| Черновик публикации и фотографии сообщества | `lib/data/community_draft_store.dart`, `lib/widgets/community_photo_viewer.dart`; черновик раздельно по аккаунтам, аудитория и приватные фото — `community_service.dart` |
| Статистика сообщества и события реакций | `lib/widgets/community_activity_panel.dart`, `lib/services/community_activity_service.dart`, `lib/services/community_inbox_service.dart`, `lib/screens/community_post_screen.dart` |
| Вложения и отправка постов | `lib/widgets/community_route_picker.dart`, `lib/services/community_route_choices.dart`, `lib/widgets/community_post_share_sheet.dart`, `lib/widgets/community_post_chat_link.dart`, `lib/models/community_post_topic.dart` |
| Сообщество и события | `lib/services/community_service.dart`, `lib/services/events_service.dart`, `lib/screens/events_screen.dart` |
| Совместные поездки и клубы | `lib/services/group_ride_service.dart`, `lib/services/club_service.dart` |
| Гараж и обслуживание | `lib/services/garage_service.dart`; связанные экраны и виджеты искать по `garage`/`bike` |
| Цели и достижения | `lib/services/achievements_service.dart`, `lib/services/goals_service.dart`, `lib/data/progress_goals_repository.dart` |
| Пользовательские места | `lib/data/saved_places_repository.dart`, `lib/services/route_places_service.dart` |
| Авторизация и данные пользователя | `lib/services/auth_service.dart`, `lib/data/user_scope.dart`, `lib/data/local_data_integrity.dart` |
| Обновления приложения | `lib/services/app_update_service.dart`, `lib/config/app_variant.dart`; при выпуске — `docs/GIT_AND_RELEASES_RU.md` |
| Лаборатория | Поиск `laboratory` в `lib/`; границы имитации — `docs/REAL_LABORATORY_RU.md` |

## Как читать код

Обычный путь: экран/виджет → контроллер или сервис → репозиторий → модель. Данные и модели находятся в lib/data и lib/models, оформление — lib/ui, нативная интеграция — android и ios. Конфигурация — lib/config.dart и существующие параметры сборки; секреты в документацию не записывать.

Связанные тесты искать в test по имени функции/модуля, инструменты — tools, CI — .github/workflows. Перечень выше — точки входа, а не исчерпывающее дерево и не доказательство корректности функций. Перед выводом об отсутствии функции выполнить поиск по исходникам.

Подробные руководства и исторические отчёты: [docs/README.md](docs/README.md), только по необходимости.
