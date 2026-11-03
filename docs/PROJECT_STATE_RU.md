# Текущий статус PulsePath

Обновлено 04.11.2026 (Томск).

- Текущая задача: независимая проверка выпуска 107 и серверных прав. Рабочая копия C:/PulsePathSSD/workspaces/pulsepath-release-107-verification, ветка codex/release-107-verification. APK/каталог/push и 27 целевых тестов подтверждены. На сервере отозван лишний TRUNCATE клиентских ролей на rides/live_positions/fcm_tokens; CRUD и RLS не изменились. Подробности и ограничения: RELEASE_107_VERIFICATION_RU.md.
- Стабильная 1.16.3+107 опубликована: source_commit 325f006, подпись прежняя (8cc8aaad…), GitHub SHA256/размер и анонимная загрузка проверены, каталог app_releases обновлён (вставка 107), серверный push done с первой попытки (sent_at 18:26:46 UTC, last_error=null).
- Телефон обновлён без очистки данных (install -r, versionCode 107 подтверждён dumpsys). Активная навигация и тренировка на телефоне отдельно не воспроизводились.
- Состав выпуска: защита от параллельных стартов (_startGuardBusy), старт не затирает невосстановленный черновик, повреждённый черновик не блокирует и уходит в резервную копию, ошибка достижений не проваливает сохранение (lastAchievementsError), кэш routeSegments с инвалидацией по идентичности/длине. Тесты: 784 прошли, единственное падение — предсуществующее ui_snapshot_cache («Saved feed remains visible when the network is unavailable»), проверено на чистом дереве.
- Процесс интеграции: база b379851 (1.16.2+106) + работа другого агента (3b0d59e: race-guard, D2, ownerResolver) + недостающее из 79037c4/affcf0d (исправление компиляции loadInterruptedWorkout, герметичные тесты с ownerResolver, damaged-draft, кэш + тесты) = 325f006. Ветки переноса: codex/workspace-on-d (79037c4, origin), codex/route-segments-cache (affcf0d, локально в D:/pulsepath).

