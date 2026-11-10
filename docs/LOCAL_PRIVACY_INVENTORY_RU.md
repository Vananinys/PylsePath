# Раунд 3: локальное хранение и приватность E2EE на устройстве

Дата: 10.11.2026. Read-only аудит ветки codex/chat-e2ee (HEAD d838929).
Статический анализ + локальный тест манифеста; без production, реальных
аккаунтов и данных. Не повторяет аудит push/FCM (PUSH_BETA13_AUDIT_RU.md) и
криптоалгоритма (E2EE_CRYPTO_INVARIANTS_RU.md). Пиннинг-тест — на ветке
codex/local-privacy-pinning.

## Инвентаризация хранимых данных

| Данные | Где лежит | Источник (файл:строка) | После logout |
|---|---|---|---|
| JWT/сессия Supabase | SharedPreferences открытым текстом (дефолт supabase_flutter 2.18) | local_storage.dart:67 (pub-cache), main.dart:166-175 (без debug-логов) | Удаляется `client.auth.signOut()` (auth_service.dart:241) |
| Приватные ключи E2EE (seed, recovery, пины) | FlutterSecureStorage (Keystore), ключ по аккаунту | e2ee_secret_store.dart:29-30, 38-45 | **Остаются** |
| Расшифрованный кэш истории (beta) | FlutterSecureStorage, owner-скоп, 200 последних + pending | chat_local_store.dart:20, 101-136 | **Остаются** |
| Кэш истории и черновики (stable) | SharedPreferences открытым текстом | chat_local_store.dart:137-160, 183-188 | **Остаются** |
| Расшифрованный текст как String в памяти | Dart-куча (без wiping), SecureKey.dispose только для пар | e2ee_identity_service.dart:76-197 | — |
| Вложения чата (legacy; E2EE их блокирует) | app-support/chat_pending/<owner>/, sandbox | chat_media_files_io.dart:17-32 | Остаются до удаления сообщения (очередь ChatAttachmentCleanup) |
| Голосовое до отправки (legacy) | cacheDir/voice_<id>.m4a, явного удаления temp нет | chat_screen.dart:857-861 | До очистки кэша ОС |
| SQL-базы | **Отсутствуют** (pubspec: нет sqflite/drift/sqlite/hive/isar) | pubspec.yaml | — |
| Clipboard: копирование тела расшифрованного сообщения | Системный буфер | chat_screen.dart:2037 | OS-политика очистки |
| Clipboard: recovery-ключ через выделение SelectableText | Системный буфер | e2ee_keys_screen.dart:141 | OS-политика очистки |
| Отпечатки (SHA-256) и ciphertext-конверт (тестовый экран) | SelectableText, копируемы | e2ee_keys_screen.dart:130, e2ee_test_chat_screen.dart:307 | Публичные данные |
| Логи | logcat: URL/коды ошибок; тел/ключей/seed не печатается (grep 4 файлов — чисто) | main.dart:178-179 и др. | logcat ротируется ОС |
| Crash-отчёты | Crashlytics/Sentry/ACRA отсутствуют (pubspec) — только logcat | pubspec.yaml | — |
| Скриншоты/превью recents | FLAG_SECURE только на экране ключей (ref-counted канал) | MainActivity.kt:26-37, e2ee_keys_screen.dart:23, :90 | Диалог без FLAG_SECURE скриншотится |
| История шторки/lock screen | visibility private для чат-уведомлений | push_service.dart:841 | См. отчёт задачи 2 |

## Backup и перенос (подтверждено манифестом + тест)

- `allowBackup="false"`, `usesCleartextTraffic="false"`
  (android/app/src/main/AndroidManifest.xml:28-30).
- backup_rules.xml исключает ВСЕ домены (root/file/database/sharedpref/external);
  data_extraction_rules.xml — то же в секциях cloud-backup И device-transfer
  (Android 12+ перенос на новое устройство исключён полностью).
- Пиннинг-тест test/local_privacy_pinning_test.dart (3 passed) фиксирует
  инварианты против случайной регрессии при будущих правках манифеста.

## Подтверждённое поведение кода (не OS-допущения)

1. signOut (auth_service.dart:233-257) удаляет сессию и push-токен
   (unregisterCurrentDevice), отключает фон-локацию/активность, но **не удаляет**
   кэш чатов, черновики, ключи E2EE и retained-медиа — данные сохраняются для
   аккаунта (изоляция owner-скопом, UserScope.keyFor; legacy-'_guest' ключи
   хранятся для явного восстановления, user_scope.dart:9-10). Согласовано с
   политикой «обновлять без очистки данных» (AGENTS.md), но должно быть
   явно задокументировано в релизе.
2. Копирование тела расшифрованного сообщения и recovery-ключа в системный
   буфер возможно штатными средствами UI (см. таблицу).
3. FLAG_SECURE отсутствует на экране чата → скриншоты и превью recents
   содержат расшифрованный текст (осознанный выбор; включение сломало бы
   скриншоты целиком — решение за владельцем).
4. Голосовые temp-файлы в cacheDir не удаляются явно (legacy-режим).
5. Flutter Clipboard API не поддерживает EXTRA_IS_SENSITIVE — проверено
   grep по D:/dev/flutter/packages/flutter/lib/src/services/clipboard.dart
   (Flutter 3.47.7): флаг недоступен из Dart без платформенного канала.

## OS/root допущения (отдельно от кода)

- Sandbox Android защищает files/prefs/databases от других приложений;
  root или ADB-дебаг снимает защиту — чтение shared_prefs (включая JWT) и
  файлов приложения возможно.
- Android 13+ сам очищает clipboard через тайм-аут и показывает редактор
  буфера при копировании; на Android ≤12 содержимое живёт до перезаписи;
  поведение зависит от OEM.
- Backup daemon соблюдает exclusion-правила; device-transfer на Android 12+
  уважает data_extraction_rules.
- Keystore-ключи secure storage невыводимы из устройства (hardware-backed,
  если доступно); при снятии дампа флеш-памяти (forensic) защищённость
  зависит от реализации плагина.

## Безопасный дефект/фикс

Единственный добавленный артефакт — пиннинг-тест манифеста
(codex/local-privacy-pinning, 3 passed). Изменений формата хранилищ,
механизмов миграции/удаления и security promises нет: retention-поведение
logout и отсутствие FLAG_SECURE на чате — решения владельца, зафиксированы
как рекомендации.

## Рекомендации (без правок)

1. Документировать retention после logout в релизных заметках стабильной
   версии (данные остаются на устройстве).
2. Рассмотреть опцию «удалять локальные данные при выходе» — отдельная
   функция с подтверждением пользователя (меняет механизм удаления → не
   делать в рамках аудита).
3. Голосовые temp-файлы удалять после retain (legacy-режим) — мелкое
   улучшение гигиены, вне E2EE.
4. Не размещать recovery-ключ и тело сообщения в clipboard без
   необходимости; при появлении в Flutter isSensitive — использовать.

## Ограничения

- Статический анализ; поведение на реальном устройстве (Keystore, clipboard
  OEM, backup daemon) не воспроизводилось.
- iOS-хранилища (Keychain accessibility first_unlock_this_device) не
  проверялись — вне Android-фокуса задания; отмечено в e2ee_secret_store.dart:19-23.
- Ветвление Flutter-версии clipboard может измениться в будущих SDK.
