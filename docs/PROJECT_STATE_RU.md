# Текущий статус PulsePath

Обновлено 03.11.2026 (Томск). Правила — AGENTS.md; карта — PROJECT_STRUCTURE.md.

- Основная рабочая папка теперь D:/pulsepath (приложение1.16.0+104). Остальные ветки и оригинальная папка с незакоммиченными правками сохранены в D:/pulsepath-worktrees. Эту папку сохранять: D:/pulsepath/.git ссылается на общую Git-базу в main-original/.git. Старый проект, ранее находившийся на D:, сохранён в D:/pulsepath-before-migration-20261103.
- Проект скопирован и сверен SHA256:9 копий,6855 файлов, без расхождений. Git-связи восстановлены для D:, история доступна. Исходные рабочие папки проекта на C: не удалялись; generated build/.dart_tool/.gradle не переносились, offline Maven mirror сохранён отдельно в build-archive.
- Flutter D:/dev/flutter; SDK D:/Android/Sdk; Gradle D:/Gradle; Android/AVD D:/Android/User. Старые пути инструментов на C: — junction-ссылки. Данные эмулятора сверены полной SHA256, SDK/кэши — по всем размерам/датам и контрольным суммам основных инструментов. Ключ подписи D:/pulsepath-private/keys, проверен; пароли не менялись.
- Проверено: Flutter/Dart, ADB, Gradle запускаются с D:, flutter pub get --offline проходит. Переменные окружения пользователя обновлены. Build script перенастроен на D:. Новый APK для переноса файлов не выпускался; исходники приложения не менялись.
- Релиз1.16.0 ранее опубликован; физические загрузка/воспроизведение видео и проверка двух аккаунтов остаются открытыми. Доказательства переноса: D:/pulsepath-migration-verification.json, D:/pulsepath-toolchain-verified.json, D:/pulsepath-android-user-verified.json, D:/pulsepath-migration-completed.json.
