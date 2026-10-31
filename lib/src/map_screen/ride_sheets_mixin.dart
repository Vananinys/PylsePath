part of '../../main.dart';

/// Нижняя панель заезда, HUD предзапуска и действия с панелью друга
/// на карте (профиль, удаление, стикеры).
mixin _RideSheetsMixin on _MapScreenStateBase {
  void _onGroupPreparationRequested() {
    if (!mounted || !_isForeground) return;
    final request = GroupWorkoutNavigation.instance;
    final group = GroupRideService();
    final room = request.roomId, owner = request.userId;
    request.consume();
    if (!mounted ||
        owner == null ||
        owner != group.userId ||
        room == null ||
        room != group.activeRoomId)
      return;
    if (_isScreenLocked || _navigationController.isSavingWorkout) {
      _showSnackBar(
        'Поездка подключена. Откройте подготовку после завершения текущего действия.',
      );
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
    if (_navigationController.isWorkoutActive ||
        _navigationController.isWorkoutPaused) {
      _showSnackBar(
        'Приглашение принято. Текущая запись продолжается; совместную тренировку можно настроить после её сохранения.',
      );
      return;
    }
    _searchFocusNode.unfocus();
    setState(() {
      _preRideGroupRoomId = room;
      _isPreRideOpen = true;
      _isChoosingRoute = false;
    });
    unawaited(_loadPreRideWeather());
  }

  Future<void> _openGroupFromPreparation() async {
    if (_isScreenLocked) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            GroupRideScreen(navigationController: _navigationController),
      ),
    );
    if (!mounted) return;
    setState(() {
      _isPreRideOpen = true;
      _preRideGroupRoomId = GroupRideService().activeRoomId;
    });
  }

  /// Нижняя панель карты в стиле Komoot: второстепенные действия (история,
  /// сохранённые маршруты) и главная кнопка «Свободный заезд», по нажатию
  /// на которую раскрывается HUD подготовки ([PreRideWidget]).
  Widget _buildRideBottomBar() {
    return MapHomeActions(
      onWorkout: _isScreenLocked
          ? null
          : () {
              _searchFocusNode.unfocus();
              setState(() {
                _isPreRideOpen = true;
                _isChoosingRoute = false;
              });
              _loadPreRideWeather();
            },
      onRoute: _isScreenLocked ? null : _openRoutePlanner,
    );
  }

  Future<void> _openRoutePlanner() async {
    if (_isScreenLocked) return;
    _searchFocusNode.unfocus();
    final action = await showRouteEntrySheet(context);
    if (!mounted || action == null) return;
    setState(() {
      _isPreRideOpen = false;
      _isChoosingRoute = false;
    });
    switch (action) {
      case RouteEntryAction.search:
        setState(() => _isChoosingRoute = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocusNode.requestFocus();
        });
      case RouteEntryAction.map:
        setState(() => _isChoosingRoute = true);
        _showSnackBar('Удерживайте нужное место на карте и выберите маршрут');
      case RouteEntryAction.saved:
        _openSavedRoutes();
      case RouteEntryAction.constructor:
        final saved = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => RouteBuilderScreen(
              initialCenter: _navigationController.currentLocation,
            ),
          ),
        );
        if (saved == true && mounted) _openSavedRoutes();
      case RouteEntryAction.myPlaces:
        _openMyPlaces();
      case RouteEntryAction.roundTrip:
        _openRoundTripPlanner();
    }
  }

  /// Погода в точке старта для HUD предзапуска (Open-Meteo, best effort:
  /// офлайн — полоса просто не показывается).
  Future<void> _loadPreRideWeather() async {
    if (_weatherLoading ||
        (_lastWeatherFetchAt != null &&
            DateTime.now().difference(_lastWeatherFetchAt!) <
                const Duration(minutes: 2))) {
      return;
    }
    _weatherLoading = true;
    if (mounted) setState(() {});
    try {
      final weather = await WeatherService().fetchCurrent(
        _navigationController.currentLocation,
      );
      _lastWeatherFetchAt = DateTime.now();
      if (!mounted) return;
      setState(() => _preRideWeather = weather);
    } finally {
      _weatherLoading = false;
      if (mounted) setState(() {});
    }
  }

  /// Шторка выбора техники для HUD предзапуска.
  Future<void> _openVehicleSelector() async {
    if (_isScreenLocked) return;
    final selected = await showVehicleSelectorSheet(
      context,
      selected: _navigationController.preRideVehicle,
      loadVehicles: () => _navigationController.fetchGarageVehicles(),
      onAddVehicle: () async {
        // Открываем Гараж; после возврата шторка перезагрузит список, а мы
        // подтянем новую активную технику, если ничего не выбрано вручную.
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const GarageScreen()),
        );
        await _navigationController.fetchGarageVehicles();
        await _navigationController.initPreRideVehicle();
      },
    );
    if (selected != null) {
      _navigationController.setPreRideVehicle(selected);
    }
  }

  /// «ПОЕХАЛИ»: старт записи трека. Техника уже привязана в контроллере
  /// (preRideVehicle или активная из гаража).
  void _setRideSharing(bool enabled) {
    _navigationController.setShareLivePosition(enabled);
    unawaited(widget.settings.setShareLivePosition(enabled));
  }

  @override
  Future<void> _startRide() async {
    if (_isScreenLocked ||
        _startingRide ||
        _navigationController.isWorkoutActive ||
        _navigationController.isWorkoutPaused) {
      return;
    }
    _startingRide = true;
    final group = GroupRideService();
    final selectedRoom = _preRideGroupRoomId;
    final selectedOwner = group.userId;
    final selectedRevision = group.membershipRevision;
    bool selectionValid() =>
        selectedRoom == null ||
        (selectedRoom == group.activeRoomId &&
            selectedOwner != null &&
            selectedOwner == group.userId &&
            selectedRevision == group.membershipRevision);
    await _navigationController.refreshEquipment();
    if (!mounted) {
      _startingRide = false;
      return;
    }
    _navigationController.setCalorieWeightKg(
      context.read<ProfileProvider>().profile.weightKg,
    );
    try {
      if (selectedRoom != null) {
        await group.refreshMembers();
        if (!mounted || !selectionValid() || group.error != null) {
          if (mounted)
            _showSnackBar(
              'Не удалось подтвердить группу. Откройте её или выберите самостоятельную поездку.',
            );
          return;
        }
      }
      if (_navigationController.gpsSignal.value.quality != GpsQuality.good) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('GPS ещё не готов'),
            content: const Text(
              'Время начнёт считаться сразу. Трек будет записываться, когда появятся точные координаты. Можно подождать на открытом месте или начать сейчас.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Подождать'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Начать без GPS'),
              ),
            ],
          ),
        );
        if (proceed != true || !mounted) return;
      }
      _navigationController.prepareWorkoutActivity();
      if (_navigationController.finishPoint != null &&
          _navigationController.routePoints.isEmpty) {
        try {
          await _navigationController.buildRoute();
        } catch (_) {
          if (mounted)
            _showSnackBar(
              'Не удалось подготовить маршрут. Повторите построение перед стартом.',
            );
          return;
        }
        if (!mounted || !_isForeground) return;
        if (_navigationController.routePoints.isEmpty) {
          _showSnackBar(
            'Маршрут ещё не готов. Повторите построение перед стартом.',
          );
          return;
        }
      }
      if (_navigationController.selectedActivity.isFoot) {
        final steps = DailyActivityService.instance;
        if (!steps.ready) await steps.initialize();
        if (!steps.enabled) await steps.setEnabled(true);
        if (!mounted || !_isForeground) return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const RideCountdown(),
      );
      if (confirmed != true || !mounted || !_isForeground) return;
      if (!selectionValid()) {
        _showSnackBar(
          'Группа изменилась во время подготовки. Выберите её заново.',
        );
        return;
      }
      if (_navigationController.routePoints.isNotEmpty &&
          !_navigationController.isNavigating) {
        _navigationController.toggleNavigation();
      }
      _navigationController.startWorkout(groupRoomId: selectedRoom);
      setState(() => _isPreRideOpen = false);
      _setCameraLockMode(CameraLockMode.followAndHeading);
      if (_isMapReady) _mapController.move(_displayPosition.value, 17);
    } finally {
      _startingRide = false;
    }
  }

  Future<void> _finishRide() async {
    if (_isScreenLocked ||
        _finishingRide ||
        _navigationController.isSavingWorkout) {
      return;
    }
    _finishingRide = true;
    final wasActive = _navigationController.isWorkoutActive;
    if (wasActive) _navigationController.pauseWorkout();
    try {
      final request = await showModalBottomSheet<WorkoutFinishRequest>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => WorkoutFinishSheet(controller: _navigationController),
      );
      if (!mounted) return;
      if (request == null) {
        if (wasActive) _navigationController.resumeWorkout();
        return;
      }
      if (request.discard) {
        await _navigationController.discardWorkout();
        if (mounted) _showSnackBar('Запись удалена без сохранения');
        return;
      }
      final history = WorkoutHistoryRepository();
      await history.load();
      final previous = List<SavedRoute>.of(history.workoutHistory);
      final previousBadges = AchievementsService.badges(previous)
          .where((b) => b.earned)
          .map((b) => b.title)
          .toSet();
      final saved = await _navigationController.finishAndSaveWorkout(
        title: request.title,
        notes: request.notes,
        effort: request.effort,
      );
      if (!mounted || saved == null) return;
      final records = PersonalRecords.newRecords(previous, saved);
      final newBadges =
          AchievementsService.badges([
                ...previous.where((r) => r.localId != saved.localId),
                saved,
              ])
              .where((b) => b.earned && !previousBadges.contains(b.title))
              .map((b) => b.title)
              .toList();
      NotificationService.instance.pushSystem(
        'Тренировка сохранена',
        subtitle: '${saved.distanceKm.toStringAsFixed(2)} км — на устройстве',
      );
      if (records.isNotEmpty || newBadges.isNotEmpty) {
        NotificationService.instance.pushSystem(
          'Новые личные результаты',
          subtitle:
              'Рекордов: ${records.length}, достижений: ${newBadges.length}.',
        );
      }
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => WorkoutDetailScreen(
            workout: WorkoutRecord.fromSavedRoute(saved),
            highlights: [
              ...records,
              ...newBadges.map((title) => 'Достижение: $title'),
            ],
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        _showSnackBar(
          'Не удалось завершить: $error. Запись осталась на паузе.',
        );
      }
    } finally {
      _finishingRide = false;
    }
  }

  /// Публичный профиль друга (из меню «…» панели).
  Future<void> _openFriendProfile(friend) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            PublicProfileScreen(userId: friend.id, preloaded: friend),
      ),
    );
    // Профиль мог измениться — обновляем список друзей на карте.
    await _navigationController.refreshFriends();
  }

  /// Удалить друга из панели на карте (с подтверждением).
  Future<void> _removeMapFriend(friend) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить из друзей?'),
        content: Text(
          '«${friend.username}» больше не будет видеть вас на карте.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _friendServiceInstance.removeFriend(friend.id);
    await _navigationController.refreshFriends();
    if (!mounted) return;
    setState(() => _selectedMapFriend = null);
    _showSnackBar('Друг удалён');
  }

  /// Стикер: отправка в чат + анимация прилёта на маркер друга.
  /// Долгое нажатие — визуальный «дождь», один жест отправляет одно сообщение.
  Future<void> _flySticker(
    friend,
    String emoji, {
    bool rain = false,
    Offset origin = Offset.zero,
  }) async {
    if (!_isMapReady || !mounted) return;
    final point = friend.liveLatitude != null && friend.liveLongitude != null
        ? LatLng(friend.liveLatitude!, friend.liveLongitude!)
        : null;
    final id = 'effect_${++_stickerSequence}';
    if (point != null) {
      _flyingStickersNotifier.value = [
        ..._flyingStickersNotifier.value,
        MapStickerEffect(
          id: id,
          point: point,
          emoji: emoji,
          origin: origin,
          rain: rain,
        ),
      ];
    }
    // One gesture sends one message; the rain is a visual effect, not eight notifications.
    try {
      await ChatService().sendMessage(friend.id, sticker: emoji);
      if (mounted) unawaited(ChatService().refreshUnread());
    } catch (_) {
      if (mounted) _showSnackBar('Стикер не отправлен. Проверьте соединение.');
    }
  }
}
