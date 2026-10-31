part of '../../main.dart';

/// Боковое меню (дровер): пункты из реестра модулей, аватар, версия, выход.
mixin _DrawerBuilderMixin on _MapScreenStateBase {
  /// Читает версию из метаданных сборки, чтобы не дублировать её строкой в UI.
  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        // Показываем только имя версии из pubspec («1.1.67-beta»).
        // Номер сборки (+2) — служебный: он остаётся в versionCode/CFBundleVersion,
        // но пользователю не нужен.
        _appVersion = info.version;
      });
    } catch (error) {
      // В тестах/на неподдерживаемой платформе плагина может не быть —
      // просто остаёмся без версии в подписи.
      debugPrint('[App] Не удалось получить версию приложения: $error');
    }
  }

  /// Выход из аккаунта: чистим сессию, закрываем дровер и возвращаемся
  /// на корневой экран (AuthGate покажет LoginScreen).
  Future<void> _signOut() async {
    if (_navigationController.isWorkoutActive ||
        _navigationController.isWorkoutPaused ||
        _navigationController.isSavingWorkout) {
      _showSnackBar('Сначала завершите и сохраните заезд');
      return;
    }
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    navigator.pop(); // закрыть дровер

    try {
      await AuthService().signOut();
      if (!mounted) return;
      navigator.popUntil((route) => route.isFirst);
      messenger.showSnackBar(
        const SnackBar(content: Text('Вы вышли из аккаунта')),
      );
    } on AuthServiceException catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// Бейдж с числом (непрочитанные сообщения / уведомления) в пункте дровера.
  Widget _buildDrawerBadge(int value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.deepOrange,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$value',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildAppDrawer(BuildContext context) {
    // Реальный профиль из общего кэша (а не захардкоженный «PulsePath Rider»).
    final profileProvider = context.watch<ProfileProvider>();
    final profile = profileProvider.profile;
    // Пункты дровера собираются из реестра модулей: выключенный модуль
    // просто не попадает в список (Этап 0 — настраиваемость).
    final enabledModules = effectiveEnabledModules(profile);
    final moduleTiles = <String, Widget>{
      'saved_routes': ListTile(
        leading: const Icon(Icons.map_outlined, color: Colors.deepOrange),
        title: const Text('Сохранённые маршруты'),
        subtitle: const Text('Готовые пути и избранное'),
        onTap: () {
          UsageStatistics.instance.record(UsageEvent.savedRoutesOpened);
          Navigator.pop(context);
          _openSavedRoutes();
        },
      ),
      'chats': ListTile(
        leading: const Icon(
          Icons.chat_bubble_outline,
          color: Colors.deepOrange,
        ),
        title: const Text('Сообщения'),
        subtitle: const Text('Чат с друзьями'),
        trailing: ValueListenableBuilder<int>(
          valueListenable: ChatService.unreadTotal,
          builder: (context, unread, _) =>
              unread > 0 ? _buildDrawerBadge(unread) : const SizedBox.shrink(),
        ),
        onTap: () {
          UsageStatistics.instance.record(UsageEvent.chatsOpened);
          Navigator.pop(context);
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const ChatsListScreen()),
          ).then((_) => ChatService().refreshUnread());
        },
      ),
      'community': ListTile(
        leading: const Icon(Icons.people_outline, color: Colors.deepOrange),
        title: const Text('Сообщество'),
        subtitle: const Text('Лента, друзья, видимость на карте'),
        onTap: () {
          UsageStatistics.instance.record(UsageEvent.communityOpened);
          Navigator.pop(context);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  FriendsScreen(navigationController: _navigationController),
            ),
          );
        },
      ),
      'history': ListTile(
        leading: const Icon(Icons.history, color: Colors.deepOrange),
        title: const Text('Тренировочный центр'),
        subtitle: const Text('Календарь, динамика и история'),
        onTap: () {
          UsageStatistics.instance.record(UsageEvent.trainingOpened);
          Navigator.pop(context);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const TrainingCenterScreen(),
            ),
          );
        },
      ),
      'achievements': ListTile(
        leading: const Icon(
          Icons.emoji_events_outlined,
          color: Colors.deepOrange,
        ),
        title: const Text('Достижения'),
        subtitle: const Text('Рекорды и бейджи'),
        onTap: () {
          UsageStatistics.instance.record(UsageEvent.achievementsOpened);
          Navigator.pop(context);
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const AchievementsScreen()),
          );
        },
      ),
      'heatmap': ListTile(
        leading: const Icon(
          Icons.local_fire_department_outlined,
          color: Colors.deepOrange,
        ),
        title: const Text('Тепловая карта'),
        subtitle: const Text('Все ваши заезды на одной карте'),
        onTap: () {
          UsageStatistics.instance.record(UsageEvent.heatmapOpened);
          Navigator.pop(context);
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const RideHeatmapScreen()),
          );
        },
      ),
      'offline_maps': ListTile(
        leading: const Icon(
          Icons.offline_pin_outlined,
          color: Colors.deepOrange,
        ),
        title: const Text('Офлайн-карты'),
        subtitle: const Text('Проверить карты для поездки без сети'),
        onTap: () {
          UsageStatistics.instance.record(UsageEvent.offlineMapsOpened);
          Navigator.pop(context);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => OfflineMapsScreen(
                currentLocation: LatLngWithLabel(
                  latitude: _navigationController.currentLocation.latitude,
                  longitude: _navigationController.currentLocation.longitude,
                ),
              ),
            ),
          );
        },
      ),
      'group_rides': ListTile(
        leading: const Icon(Icons.groups_2, color: Colors.deepOrange),
        title: const Text('Совместная поездка'),
        subtitle: const Text('Катайте вместе с друзьями'),
        onTap: () async {
          UsageStatistics.instance.record(UsageEvent.groupOpened);
          Navigator.pop(context);
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  GroupRideScreen(navigationController: _navigationController),
            ),
          );
          if (!mounted) return;
          if ((result == 'start' || result == 'prepare_group') &&
              !_navigationController.isWorkoutActive &&
              !_navigationController.isWorkoutPaused) {
            setState(() {
              _preRideGroupRoomId = GroupRideService().activeRoomId;
              _isPreRideOpen = true;
            });
          }
          if (result is LatLng && _isMapReady) {
            _setCameraLockMode(CameraLockMode.free);
            _mapController.move(result, 16);
          }
        },
      ),
      'garage': ListTile(
        leading: const Icon(Icons.pedal_bike, color: Colors.deepOrange),
        title: const Text('Мой гараж'),
        subtitle: const Text('Велосипеды и экипировка'),
        onTap: () async {
          UsageStatistics.instance.record(UsageEvent.garageOpened);
          final provider = context.read<ProfileProvider>();
          Navigator.pop(context);
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const GarageScreen()),
          );
          if (mounted) {
            await provider.refreshGarage();
            await _navigationController.refreshPrimaryVehicle();
          }
        },
      ),
    };
    return Drawer(
      child: Column(
        children: [
          UserAccountsDrawerHeader(
            decoration: const BoxDecoration(color: Colors.deepOrange),
            currentAccountPicture: _buildDrawerAvatar(profile),
            accountName: Text(
              profile.username.trim().isEmpty
                  ? 'Райдер'
                  : profile.username.trim(),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            accountEmail: Text('${profile.status} • ${profile.city}'),
          ),
          Expanded(
            child: NavigationMenu(
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.person_outline,
                    color: Colors.deepOrange,
                  ),
                  title: const Text('Профиль'),
                  subtitle: const Text('Статистика, достижения'),
                  onTap: () async {
                    // Захватываем ДО push: контекст дровера — под провайдером,
                    // а контекст билдера маршрута — уже нет.
                    final profileProvider = context.read<ProfileProvider>();
                    Navigator.pop(context);
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            ProfileScreen(provider: profileProvider),
                      ),
                    );
                    if (mounted) {
                      await _navigationController.refreshPrimaryVehicle();
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.place_outlined,
                    color: Colors.deepOrange,
                  ),
                  title: const Text('Мои места'),
                  subtitle: const Text('Личные точки на этом устройстве'),
                  onTap: () {
                    Navigator.pop(context);
                    _openMyPlaces();
                  },
                ),
                // Модульные пункты — только включённые, в порядке реестра.
                if (AppVariant.uiBeta)
                  ListTile(
                    leading: const Icon(Icons.diversity_3_outlined),
                    title: const Text('Клубы'),
                    subtitle: const Text('Участники, чат и клубные события'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ClubsScreen()),
                      );
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.event_available_outlined),
                  title: const Text('События и челленджи'),
                  subtitle: const Text('Бета-тест, опросы и награды'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const EventsScreen()),
                    );
                  },
                ),
                for (final module in UiModules.drawerModules)
                  if (enabledModules.contains(module.id))
                    moduleTiles[module.id]!,
                ListTile(
                  leading: const Icon(
                    Icons.notifications_outlined,
                    color: Colors.deepOrange,
                  ),
                  title: const Text('Уведомления'),
                  subtitle: const Text('Заявки в друзья, события'),
                  trailing: ValueListenableBuilder<int>(
                    valueListenable: NotificationService.badge,
                    builder: (context, count, _) => count > 0
                        ? _buildDrawerBadge(count)
                        : const SizedBox.shrink(),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const NotificationsScreen(),
                      ),
                    ).then((_) {
                      NotificationService.instance.refresh();
                      ChatService().refreshUnread();
                    });
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(
                    Icons.directions_walk,
                    color: Colors.deepOrange,
                  ),
                  title: const Text('Активность за день'),
                  subtitle: const Text('Шаги, дневная цель и калории'),
                  onTap: () {
                    final weight = profile.weightKg;
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DailyActivityScreen(weightKg: weight),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Настройки'),
                  subtitle: const Text('Тема, запись, приватность и аккаунт'),
                  onTap: () {
                    // Захватываем ДО push: контекст дровера — под провайдером,
                    // а контекст билдера маршрута — уже нет.
                    final profileProvider = context.read<ProfileProvider>();
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SettingsScreen(
                          canSignOut: () =>
                              !_navigationController.isWorkoutActive &&
                              !_navigationController.isWorkoutPaused &&
                              !_navigationController.isSavingWorkout,
                          settings: widget.settings,
                          onWaterReminderChanged:
                              _navigationController.setWaterReminderMinutes,
                          onGearLabChanged:
                              _navigationController.setGearLabEnabled,
                          onBackgroundChanged: (value) => _navigationController
                              .setBackgroundTrackingEnabled(value),
                          onShareLivePositionChanged: (value) =>
                              _navigationController.setShareLivePosition(value),
                          provider: profileProvider,
                        ),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('О приложении'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const AboutScreen(),
                      ),
                    );
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.logout, color: Colors.red),
                  title: const Text(
                    'Выйти',
                    style: TextStyle(color: Colors.red),
                  ),
                  onTap: _signOut,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16.0),
            alignment: Alignment.centerLeft,
            child: Text(
              // Версия подтягивается из pubspec.yaml через метаданные сборки.
              _appVersion == null
                  ? AppVariant.name
                  : '${AppVariant.name} v$_appVersion',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// Аватар в дровере: локальное фото → облачный URL → буква имени.
  Widget _buildDrawerAvatar(UserProfile profile) {
    final ImageProvider? image;
    final photoPath = profile.photoPath;
    final avatarUrl = profile.avatarUrl;
    if (photoPath != null && File(photoPath).existsSync()) {
      image = FileImage(File(photoPath));
    } else if (avatarUrl != null &&
        (avatarUrl.startsWith('http://') || avatarUrl.startsWith('https://'))) {
      image = NetworkImage(avatarUrl);
    } else {
      image = null;
    }
    return CircleAvatar(
      backgroundColor: Colors.white,
      backgroundImage: image,
      child: image == null
          ? Text(
              profile.username.trim().isEmpty
                  ? 'Р'
                  : profile.username.trim().characters.first.toUpperCase(),
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.deepOrange.shade800,
              ),
            )
          : null,
    );
  }
}
