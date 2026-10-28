import 'app_versions_screen.dart';
import 'usage_statistics_screen.dart';
import '../widgets/home_steps_pill.dart';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../widgets/voice_guidance_settings.dart';

import '../data/app_settings.dart';
import 'navigation_preferences_screen.dart';
import 'owner_screen.dart';
import '../services/owner_service.dart';
import 'ride_heatmap_screen.dart';
import '../data/ui_modules.dart';
import '../widgets/module_settings_panel.dart';
import 'daily_activity_screen.dart';
import '../services/auth_service.dart';
import '../services/app_update_service.dart';
import '../state/profile_provider.dart';
import '../services/notification_permission_service.dart';
import '../services/workout_reminder_clock.dart';
import '../services/push_service.dart';
import '../widgets/background_location_settings.dart';
import '../widgets/app_update_dialog.dart';
import 'progress_backup_screen.dart';
import '../widgets/settings_hub.dart';
import 'privacy_screen.dart';

/// Экран настроек приложения: параметры заезда по умолчанию (автопауза,
/// электропривод), интерфейс (пресет и модули), информация о синхронизации
/// и выход из аккаунта.
///
/// После `auth.signOut()` корневой [AuthGate] по onAuthStateChange сам
/// переключает экран на `LoginScreen`, поэтому достаточно сбросить стек
/// навигации к корню.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.authService,
    this.canSignOut,
    this.settings,
    this.onBackgroundChanged,
    this.onShareLivePositionChanged,
    this.provider,
    this.onGearLabChanged,
    this.onWaterReminderChanged,
  });

  /// Позволяет подставить сервис в тестах.
  final AuthService? authService;
  final bool Function()? canSignOut;

  /// Настройки приложения (значения по умолчанию для заездов).
  final AppSettings? settings;

  /// Вызывается при переключении фонового режима — карта перезапускает
  /// GPS-поток без перезапуска приложения.
  final ValueChanged<bool>? onBackgroundChanged;

  /// Вызывается при переключении трансляции живой позиции друзьям —
  /// контроллер карты прекращает/возобновляет публикацию.
  final ValueChanged<bool>? onShareLivePositionChanged;

  /// Профиль для секции «Интерфейс». Экран открывается через Navigator.push,
  /// поэтому добраться до ProfileProvider через контекст нельзя (он ниже
  /// навигатора) — передаём явно, как это делает ProfileScreen.
  final ProfileProvider? provider;
  final ValueChanged<bool>? onGearLabChanged;
  final ValueChanged<int>? onWaterReminderChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _signingOut = false;
  bool _autoPause = true;
  bool _background = true;
  bool _shareLive = false;
  bool _settingsLoaded = false;
  bool _checkingUpdate = false;
  bool _gearLab = false;
  bool _isOwner = false;
  int _waterMinutes = 0;
  bool _savingWater = false;
  int _waterFieldRevision = 0;

  AuthService get _auth => widget.authService ?? AuthService();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadOwner();
  }

  Future<void> _loadOwner() async {
    try {
      final rights = await OwnerService().entitlements();
      if (mounted) setState(() => _isOwner = rights['is_owner'] == true);
    } catch (_) {
      /* No privileged UI without server confirmation. */
    }
  }

  Future<void> _loadSettings() async {
    final settings = widget.settings ?? AppSettings();
    await settings.load();
    if (!mounted) return;
    setState(() {
      _autoPause = settings.autoPauseEnabled;
      _background = settings.backgroundTracking;
      _shareLive = settings.shareLivePosition;
      _gearLab = settings.gearLabEnabled;
      _waterMinutes = settings.waterReminderMinutes;
      _settingsLoaded = true;
    });
  }

  Future<void> _updateSettings({
    bool? autoPause,
    bool? background,
    bool? shareLive,
  }) async {
    final settings = widget.settings ?? AppSettings();
    if (autoPause != null) {
      setState(() => _autoPause = autoPause);
      await settings.setAutoPauseEnabled(autoPause);
    }
    if (background != null) {
      setState(() => _background = background);
      await settings.setBackgroundTracking(background);
      widget.onBackgroundChanged?.call(background);
    }
    if (shareLive != null) {
      setState(() => _shareLive = shareLive);
      await settings.setShareLivePosition(shareLive);
      widget.onShareLivePositionChanged?.call(shareLive);
    }
  }

  Future<void> _changeWaterReminder(int minutes) async {
    if (_savingWater || minutes == _waterMinutes) return;
    setState(() => _savingWater = true);
    try {
      if (minutes > 0 && !await NotificationPermissionService.request()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Разрешите уведомления PulsePath в настройках телефона, чтобы получать напоминания.',
              ),
            ),
          );
        }
        return;
      }
      await (widget.settings ?? AppSettings()).setWaterReminderMinutes(minutes);
      widget.onWaterReminderChanged?.call(minutes);
      if (mounted) setState(() => _waterMinutes = minutes);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось сохранить интервал. Попробуйте ещё раз.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _savingWater = false;
          _waterFieldRevision++;
        });
      }
    }
  }

  /// Выход из аккаунта с возвратом на экран входа.
  Future<void> _signOut() async {
    if (widget.canSignOut != null && !widget.canSignOut!()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала завершите и сохраните заезд')),
      );
      return;
    }
    setState(() => _signingOut = true);
    // Забираем ссылки до await: к моменту завершения signOut контекст может
    // быть уже размонтирован.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _auth.signOut();
      if (!mounted) return;
      // Возврат к корневому экрану: там AuthGate уже показывает LoginScreen.
      navigator.popUntil((route) => route.isFirst);
      messenger.showSnackBar(
        const SnackBar(content: Text('Вы вышли из аккаунта')),
      );
    } on AuthServiceException catch (error) {
      if (!mounted) return;
      setState(() => _signingOut = false);
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _confirmSignOut() async {
    if (_signingOut) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content: const Text(
          'Чтобы снова синхронизировать профиль и заезды, потребуется войти.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _signOut();
    }
  }

  Future<void> _checkForUpdates() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      await showAppUpdateDialog(context);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось открыть проверку обновлений'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Widget _buildPrivacySection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Приватность',
            style: TextStyle(
              color: Colors.grey,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.policy_outlined),
          title: const Text('Данные и согласия'),
          subtitle: const Text(
            'Возрастная группа, документы и обращения оператору',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PrivacyScreen()),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.share_location),
          title: const Text('Транслировать позицию друзьям'),
          subtitle: const Text(
            'Друзья видят вашу позицию на карте. Для обновлений без открытого приложения включите отдельный режим ниже.',
          ),
          value: _settingsLoaded && _shareLive,
          onChanged: _settingsLoaded
              ? (value) => _updateSettings(shareLive: value)
              : null,
        ),
        BackgroundLocationSettings(shareAllowed: _shareLive),
        ListTile(
          leading: const Icon(Icons.cloud_sync_outlined),
          title: const Text('Резервная копия и восстановление'),
          subtitle: const Text('Заезды, шаги, цели и достижения'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ProgressBackupScreen()),
          ),
        ),
        // Поля профиля управляются через провайдер (сохраняются в profiles).
        ListenableBuilder(
          listenable: Listenable.merge([
            if (widget.provider != null) widget.provider!,
          ]),
          builder: (context, _) {
            final profile = widget.provider?.profile;
            if (profile == null) return const SizedBox.shrink();
            return Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.monitor_weight_outlined),
                  title: const Text('Показывать вес другим'),
                  subtitle: const Text('В публичном профиле и у друзей'),
                  value: profile.showWeight,
                  onChanged: (value) =>
                      widget.provider?.updateProfile(showWeight: value),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.cake_outlined),
                  title: const Text('Показывать возраст другим'),
                  subtitle: const Text('В публичном профиле и у друзей'),
                  value: profile.showAge,
                  onChanged: (value) =>
                      widget.provider?.updateProfile(showAge: value),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.wc_outlined),
                  title: const Text('Показывать пол другим'),
                  subtitle: const Text('В публичном профиле и у друзей'),
                  value: profile.showGender,
                  onChanged: (value) =>
                      widget.provider?.updateProfile(showGender: value),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  // ── Интерфейс: пресет и модули (Этап 0) ──────────────────────────────

  Widget _buildInterfaceSection(BuildContext context) {
    final provider = widget.provider;
    // Без провайдера секцию не показываем (защита для тестов/легаси-вызовов).
    if (provider == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: provider,
      builder: (context, _) {
        final preset = UiPreset.fromId(provider.profile.uiPreset);
        final enabled = effectiveEnabledModules(provider.profile);
        return Card(
          margin: const EdgeInsets.all(12),
          child: ListTile(
            leading: const Icon(Icons.dashboard_customize_outlined),
            title: const Text('Модули приложения'),
            subtitle: Text(
              '${enabled.intersection(UiModules.allIds).length} из ${UiModules.allIds.length} включено · ${preset.title}\nВыбор разделов, готовые наборы и объяснение каждой функции',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (screenContext) => Scaffold(
                  appBar: AppBar(title: const Text('Модули приложения')),
                  body: ListenableBuilder(
                    listenable: provider,
                    builder: (_, _) => ListView(
                      children: [
                        ModuleSettingsPanel(
                          enabled: effectiveEnabledModules(provider.profile),
                          preset: UiPreset.fromId(provider.profile.uiPreset),
                          onPreset: () => _pickPreset(
                            screenContext,
                            UiPreset.fromId(provider.profile.uiPreset),
                          ),
                          onChanged: provider.setModuleEnabled,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickPreset(BuildContext context, UiPreset current) async {
    final provider = widget.provider;
    if (provider == null) return;
    final picked = await showDialog<UiPreset>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Готовые наборы функций'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Text(
              'Выбор заменит текущий набор разделов. История и награды сохранятся. Разрешения, шагомер и передача геопозиции не меняются.',
            ),
          ),
          for (final preset in UiPreset.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, preset),
              child: Row(
                children: [
                  Text(preset.emoji, style: const TextStyle(fontSize: 26)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          preset.title,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${preset.description}\n${UiModules.optionalModules.where((module) => preset.modules.contains(module.id)).map((module) => module.title).join(' · ')}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (preset == current)
                    const Icon(Icons.check, color: Colors.deepOrange),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null) {
      try {
        await provider.applyUiPreset(picked);
      } catch (_) {
        if (context.mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Не удалось сохранить набор. Попробуйте ещё раз.'),
            ),
          );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsHub(
      summaries: {
        'Внешний вид': 'Ваш набор разделов и возможности приложения',
        'Шагомер и активность': 'Шаги, дневная цель и огонёк активности',
        'Уведомления': 'Звук, вибрация и экран блокировки',
        'Тренировки':
            'Фоновая запись ${_background ? 'включена' : 'выключена'} · автопауза ${_autoPause ? 'включена' : 'выключена'}',
        'Приватность':
            'Позиция друзьям ${_shareLive ? 'передаётся' : 'не передаётся'} · видимость профиля и резервная копия',
        'Аккаунт и данные': 'Облачная синхронизация, обновления и вход',
      },
      children: [
        _sectionHeader('Внешний вид'),
        _buildInterfaceSection(context),
        const Divider(),
        _sectionHeader('Шагомер и активность'),
        const HomeStepsSetting(),
        ListTile(
          leading: const Icon(Icons.directions_walk),
          title: const Text('Шагомер и дневная цель'),
          subtitle: const Text(
            'Включение счёта шагов, разрешение физической активности, дневная цель и история. Шаги пешей тренировки сохраняются также в её итогах.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DailyActivityScreen(
                weightKg: widget.provider?.profile.weightKg ?? 70,
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            'Огонёк — серия активных дней. Сохраните за день тренировки суммарно от 10 минут движения или 1 км без автомобиля. Обычные шаги вне тренировок серию не продлевают. Прогресс — в профиле. Цели недели и коллекция медалей находятся в «Достижениях».',
          ),
        ),
        _sectionHeader('Уведомления'),
        ListTile(
          leading: const Icon(Icons.notifications_active_outlined),
          title: const Text('Системные уведомления'),
          subtitle: const Text(
            'Звук, вибрация, всплывающие баннеры и экран блокировки',
          ),
          trailing: const Icon(Icons.open_in_new),
          onTap: () async {
            final opened = await openAppSettings();
            if (!opened && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Откройте настройки телефона → PulsePath → Уведомления',
                  ),
                ),
              );
            }
          },
        ),
        _sectionHeader('Запись тренировки и помощники'),
        ListTile(
          leading: const Icon(Icons.local_fire_department_outlined),
          title: const Text('Тепловые карты тренировок'),
          subtitle: const Text('Моя история и популярные участки'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const RideHeatmapScreen()),
          ),
        ),
        if (_isOwner)
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('Владелец приложения'),
            subtitle: const Text('Проверка доступа и управление достижениями'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const OwnerScreen()),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.map_outlined),
          title: const Text('Карта и навигация'),
          subtitle: const Text(
            'Цвет маршрута, толщина линии и масштаб слежения',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const NavigationPreferencesScreen(),
            ),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.screen_lock_portrait_outlined),
          title: const Text('Фоновый режим'),
          subtitle: const Text(
            'Трек записывается даже с выключенным экраном '
            '(постоянное уведомление во время заезда)',
          ),
          value: _settingsLoaded && _background,
          onChanged: _settingsLoaded
              ? (value) => _updateSettings(background: value)
              : null,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.motion_photos_paused),
          title: const Text('Умная автопауза'),
          subtitle: const Text(
            'Пауза при остановке дольше 3 секунд, '
            'возобновление при разгоне выше 2 км/ч',
          ),
          value: _settingsLoaded && _autoPause,
          onChanged: _settingsLoaded
              ? (value) => _updateSettings(autoPause: value)
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: DropdownButtonFormField<int>(
            key: ValueKey((_waterMinutes, _waterFieldRevision)),
            initialValue: _waterMinutes,
            isExpanded: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.water_drop_outlined),
              labelText: 'Напоминать о воде',
              helperText: 'По активному времени, без учёта пауз.\nС выключенным экраном — в фоновом режиме.',
              helperMaxLines: 3,
            ),
            items: WorkoutReminderClock.intervals
                .map(
                  (minutes) => DropdownMenuItem(
                    value: minutes,
                    child: Text(
                      minutes == 0 ? 'Выключено' : 'Каждые $minutes мин',
                    ),
                  ),
                )
                .toList(),
            onChanged: !_settingsLoaded || _savingWater
                ? null
                : (value) {
                    if (value != null) _changeWaterReminder(value);
                  },
          ),
        ),
        const VoiceGuidanceSettings(),
        if (_waterMinutes > 0)
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('Проверить сигнал о воде'),
            subtitle: const Text(
              'Громкость и звук задаются в настройках уведомлений телефона',
            ),
            onTap: _savingWater
                ? null
                : () => PushService.instance.showWaterReminder(preview: true),
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.insights_outlined),
          title: const Text('Помочь улучшить PulsePath'),
          subtitle: const Text(
            'Добровольные локальные счётчики, без GPS-треков',
          ),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const UsageStatisticsScreen()),
          ),
        ),
        _sectionHeader('Приватность'),
        _buildPrivacySection(context),
        const Divider(),
        _sectionHeader('Экспериментальные функции'),
        SwitchListTile(
          secondary: const Icon(Icons.settings_suggest_outlined),
          title: const Text('Подсказка передачи велосипеда'),
          subtitle: const Text(
            'В заезде и при планировании маршрута. Укажите звёзды и окружность колеса в гараже. Текущая передача не измеряется.',
          ),
          value: _settingsLoaded && _gearLab,
          onChanged: !_settingsLoaded
              ? null
              : (value) async {
                  setState(() => _gearLab = value);
                  await (widget.settings ?? AppSettings()).setGearLabEnabled(
                    value,
                  );
                  widget.onGearLabChanged?.call(value);
                },
        ),
        const Divider(),
        if (AppUpdateService.supported) ...[
          _sectionHeader('Приложение'),
          ListTile(
            leading: const Icon(Icons.history_outlined),
            title: const Text('Версии и бета-тестирование'),
            subtitle: const Text(
              'Канал обновлений, предыдущие APK и исходный код',
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AppVersionsScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: const Text('Проверить обновления'),
            subtitle: const Text('Скачать и установить новую версию'),
            trailing: _checkingUpdate
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _checkingUpdate ? null : _checkForUpdates,
          ),
          const Divider(),
        ],

        _sectionHeader('Аккаунт и данные'),
        const ListTile(
          leading: Icon(Icons.cloud_sync_outlined),
          title: Text('Синхронизация'),
          subtitle: Text(
            'Профиль, заезды и гараж сохраняются в облако Supabase. '
            'Заезды, записанные офлайн, досылаются при открытии истории.',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.logout, color: Colors.red),
          title: const Text(
            'Выйти из аккаунта',
            style: TextStyle(color: Colors.red),
          ),
          trailing: _signingOut
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          enabled: !_signingOut,
          onTap: _confirmSignOut,
        ),
      ],
    );
  }

  /// Единый стиль заголовков секций.
  static Widget _sectionHeader(String title) => SettingsSectionHeading(title);
}
