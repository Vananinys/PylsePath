part of '../../main.dart';

/// Компас и режимы камеры: следование, поворот карты, горячие каналы
/// позиции/азимута контроллера.
mixin _CameraCompassMixin on _MapScreenStateBase {
  /// Put the current position in the visible map, above the workout panel.
  void _keepPositionAbovePanel() {
    if (!_isMapReady || !_navigationController.isFollowingUser) return;
    final tracking =
        _navigationController.isWorkoutActive ||
        _navigationController.isWorkoutPaused;
    if (!tracking) return;
    final top = _navigationController.isNavigating ? 240.0 : 130.0;
    final bottom = _workoutHudHeight;
    final height = MediaQuery.sizeOf(context).height;
    final offset = ((top - bottom) / 2)
        .clamp(-height * .3, height * .3)
        .toDouble();
    _mapController.move(
      _displayPosition.value,
      _mapController.camera.zoom,
      offset: Offset(0, offset),
    );
  }

  /// Запускает подписку на компас ПОСЛЕ проверки/запроса разрешения на
  /// геолокацию — на Android датчик ориентации молчит без него, даже если
  /// сам компас физически исправен.
  Future<void> _initCompass() async {
    final permission = await Geolocator.checkPermission();
    if (!mounted) return;
    debugPrint('[Compass] location permission = $permission');

    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) {
      debugPrint(
        '[Compass] permission refused — heading updates will not arrive',
      );
      _showSnackBar(
        'Нет доступа к геолокации: направление движения не будет отслеживаться',
      );
      return;
    }

    if (!mounted) return;
    _compassService.removeListener(_onCompassUpdate);
    _compassService.addListener(_onCompassUpdate);
    _compassService.start();
    debugPrint(
      '[Compass] started, isAvailable=${_compassService.isAvailable}, '
      'mock=${_compassService.isMockRotationActive}',
    );

    if (_compassService.isMockRotationActive) {
      if (!_mockNoticeShown) {
        _mockNoticeShown = true;
        _showSnackBar(
          'Датчик компаса недоступен — включена эмуляция вращения (отладка)',
        );
      }
    } else if (!_compassService.isAvailable) {
      _showSnackBar('На этом устройстве не найден датчик компаса');
    }
  }

  /// Единая точка входа для обновлений азимута.
  ///
  /// `CompassService` гарантирует, что `heading` никогда не «прыгает» в 0.0
  /// из-за залипшего магнитометра: при потере обоих источников он отдаёт
  /// `lastValidHeading`, а при необходимости — эмулирует вращение.
  void _onCompassUpdate() {
    if (!mounted) return;
    if (!_compassService.hasReading) {
      debugPrint(
        '[Compass] event skipped: no reading yet (sensor not calibrated / no data)',
      );
      return;
    }

    final heading = _compassService.heading;
    if (!heading.isFinite) {
      debugPrint('[Compass] event skipped: heading is not finite ($heading)');
      return;
    }

    _displayHeading.update(heading);
  }

  void _onDisplayedHeadingChanged() {
    if (!mounted) return;
    _currentHeading = _displayHeading.value;
    _navigationController.setDisplayHeading(_currentHeading);
  }

  void _onAppearanceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void _setCameraLockMode(CameraLockMode mode) {
    debugPrint('[CameraLockMode] switching to $mode');
    setState(() {
      _cameraLockMode = mode;
    });
    _navigationController.setFollowingUser(mode.isFollowing);
    _navigationController.setAutoRotateMap(mode.isRotating);

    if (!mode.isRotating && mode.isFollowing && _isMapReady) {
      // «Следовать» = «Север вверху»: гасим накопленный поворот, иначе после
      // followAndHeading карта остаётся повёрнутой на -heading и «север вверху»
      // на самом деле севером вверху не является.
      _mapController.rotate(0.0);
    }

    // Если режим free, карта не следует за пользователем
    if (mode == CameraLockMode.free) {
      // Ничего не делаем, пользователь сам управляет картой
    } else if (mode.isFollowing) {
      if (!_isMapReady) return;
      // Переместить карту к текущему местоположению.
      // Знак поворота: в flutter_map положительный rotation крутит карту
      // по часовой стрелке (Transform.rotate в экранных координатах), поэтому
      // «курс вверх» — это ровно -heading.
      if (mode.isRotating) {
        _mapController.moveAndRotate(
          _displayPosition.value,
          NavigationPreferences.instance.followZoom,
          -_currentHeading,
        );
      } else {
        _mapController.move(
          _displayPosition.value,
          NavigationPreferences.instance.followZoom,
        );
      }
    }
  }

  /// Горячий канал позиции: императивно двигаем камеру в режиме следования.
  /// Никакого setState — маркер обновляет свою точку через positionNotifier.
  void _onPositionChanged() {
    if (!mounted) return;
    _compassService.updateGpsBearing(_navigationController.currentGpsHeading);
    _displayPosition.update(_navigationController.positionNotifier.value);
    if (_centerOnNextGpsFix &&
        _navigationController.gpsSignal.value
                .checkedAt(DateTime.now())
                .quality !=
            GpsQuality.lost &&
        _navigationController.gpsSignal.value.updatedAt != null) {
      _centerOnNextGpsFix = false;
      _setCameraLockMode(CameraLockMode.follow);
    }
  }

  void _onDisplayedPositionChanged() {
    if (!_isMapReady || !_navigationController.isFollowingUser) return;
    final bool rotateMap =
        _cameraLockMode == CameraLockMode.followAndHeading &&
        _compassService.hasValidHeading;
    if (rotateMap) {
      _mapController.moveAndRotate(
        _displayPosition.value,
        _mapController.camera.zoom,
        -_currentHeading,
      );
    } else {
      _mapController.move(_displayPosition.value, _mapController.camera.zoom);
    }
    _keepPositionAbovePanel();
  }

  /// Горячий канал азимута: поворот камеры в режиме «по направлению».
  void _onHeadingChanged() {
    _currentHeading = _navigationController.headingListenable.value;
    if (!_isMapReady || !_navigationController.isFollowingUser) return;
    if (_cameraLockMode != CameraLockMode.followAndHeading) return;

    _mapController.moveAndRotate(
      _displayPosition.value,
      _mapController.camera.zoom,
      -_currentHeading,
    );
    _keepPositionAbovePanel();
  }

  /// Смена состояний контроллера (старт/пауза/финиш/маршрут/друзья) —
  /// редкие события, здесь полный rebuild экрана оправдан.
  void _handleControllerUpdate() {
    // GPS bearing из потока геолокации подкидываем в CompassService как
    // резервный источник: если магнитометр отдаёт 0.0, а устройство едет,
    // азимут возьмётся отсюда. Если и GPS отдаёт 0.0 — сервис оставит
    // последний валидный угол (или включит эмуляцию).
    _compassService.updateGpsBearing(_navigationController.currentGpsHeading);

    if (_navigationController.isFollowingUser && _isMapReady) {
      // Источник истины по углу — _currentHeading (CompassService), а не
      // navigationController.currentHeading: у второго нет fallback-логики,
      // и он «сбрасывал» карту на север при нулях от датчиков.
      final bool rotateMap =
          _cameraLockMode == CameraLockMode.followAndHeading &&
          _compassService.hasValidHeading;

      if (rotateMap) {
        _mapController.moveAndRotate(
          _displayPosition.value,
          _mapController.camera.zoom,
          -_currentHeading,
        );
      } else {
        _mapController.move(_displayPosition.value, _mapController.camera.zoom);
      }
    }
    _keepPositionAbovePanel();
    if (mounted) {
      setState(() {
        final id = _selectedMapFriend?.id;
        if (id != null) {
          _selectedMapFriend = _navigationController.friends
              .where((friend) => friend.id == id)
              .firstOrNull;
        }
      });
    }
  }

  Future<void> _initLocationTracking() async {
    try {
      await _navigationController.initLocationTracking();
    } catch (e) {
      _showSnackBar(e.toString());
    }
    if (mounted) await _initCompass();
  }

  Future<void> _refreshGpsAndCenter() async {
    if (_refreshingGps) return;
    _centerOnNextGpsFix = true;
    setState(() => _refreshingGps = true);
    try {
      await _navigationController.initLocationTracking();
      if (!mounted) return;
      final signal = _navigationController.gpsSignal.value.checkedAt(
        DateTime.now(),
      );
      if (signal.quality == GpsQuality.lost || signal.updatedAt == null) {
        _showSnackBar(
          'Свежие координаты пока не получены. Поиск GPS продолжается.',
        );
        return;
      }
      _displayPosition.update(_navigationController.currentLocation);
      _setCameraLockMode(CameraLockMode.follow);
      if (_isMapReady) {
        _mapController.move(
          _navigationController.currentLocation,
          NavigationPreferences.instance.followZoom,
        );
      }
      await _initCompass();
    } catch (error) {
      if (!mounted) return;
      final service = await Geolocator.isLocationServiceEnabled();
      final permission = await Geolocator.checkPermission();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Местоположение недоступно'),
          content: Text(
            !service
                ? 'Включите геолокацию. После возвращения позиция обновится автоматически.'
                : 'Разрешите PulsePath доступ к местоположению в настройках телефона.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Закрыть'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(c);
                if (!service) {
                  unawaited(Geolocator.openLocationSettings());
                } else if (permission == LocationPermission.deniedForever ||
                    permission == LocationPermission.denied) {
                  unawaited(Geolocator.openAppSettings());
                }
              },
              child: const Text('Настройки'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _refreshingGps = false);
    }
  }
}
