# PulsePath

Полный объединённый проект. Инструкция и результаты: [README_MERGED_RU.md](README_MERGED_RU.md).

Публикация новых Android APK и уведомления об обновлениях: [docs/APP_UPDATES_RU.md](docs/APP_UPDATES_RU.md).

На Windows с кириллицей в пути к проекту запускайте Android через `./run_android.ps1 --no-pub`. Если PowerShell сообщает, что выполнение сценариев отключено, запустите его так: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_android.ps1 --no-pub`. Это разрешает выполнение только для этого процесса и не меняет системную политику. Для сборки APK используйте `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_android.ps1 -BuildApk --debug --no-pub`. Скрипт использует временные пути для проекта, Java и кэша Gradle, отключает конфликтующий кэш Kotlin на время команды и восстанавливает окружение после завершения.

Если DNS `dl.google.com` недоступен и в `build/test_dependencies/recording-maven` есть подготовленные зависимости, скрипт автоматически включает автономный режим Gradle. Его можно включить явно: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_android.ps1 -BuildApk -Offline --release --no-pub`. `-Offline` действует на Gradle и Pub; `--no-pub` пропускает Pub. Для принудительной сетевой сборки есть `-Online`. Автономной сборке нужны заранее сохранённые зависимости и установленный Gradle. Скрипт не удаляет генерируемые кэши без отдельного параметра `-ResetGeneratedCaches`.

Проверено 22 октября 2026: исходная команда `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_android.ps1 -BuildApk --release --no-pub` успешно собрала `build/app/outputs/flutter-apk/app-release.apk` при недоступном DNS Google Maven. Локальный Maven-репозиторий подключён перед сетевыми, чтобы Gradle не выбирал неполные записи сетевого кэша. Журнал: `build/android_launcher_release_fix.log`.

Актуальные инструкции сохранения исходников, восстановления и каналов обновлений: [docs/GIT_AND_RELEASES_RU.md](docs/GIT_AND_RELEASES_RU.md).
Добровольные локальные счётчики и анализ отчётов: [docs/USAGE_STATISTICS_RU.md](docs/USAGE_STATISTICS_RU.md).
