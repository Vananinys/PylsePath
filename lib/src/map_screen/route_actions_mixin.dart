part of '../../main.dart';

/// Поиск, маршруты, сохранение/шаринг, форматтеры для шторки маршрута.
mixin _RouteActionsMixin on _MapScreenStateBase {
  Future<LatLng> _locateForPlace() async {
    bool usable(GpsSignal signal) =>
        signal.updatedAt != null &&
        signal.quality != GpsQuality.lost &&
        signal.accuracy != null &&
        signal.accuracy!.isFinite &&
        signal.accuracy! >= 0 &&
        signal.accuracy! <= 100;
    var signal = _navigationController.gpsSignal.value.checkedAt(
      DateTime.now(),
    );
    if (!usable(signal)) {
      await _navigationController.initLocationTracking();
      signal = _navigationController.gpsSignal.value.checkedAt(DateTime.now());
    }
    if (!mounted || !usable(signal)) {
      throw StateError('Дождитесь актуального GPS-положения');
    }
    return _navigationController.currentLocation;
  }

  @override
  Future<void> _openMyPlaces() async {
    final repository = SavedPlacesRepository();
    final selected = await Navigator.push<SavedPlace>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            SavedPlacesScreen(repository: repository, locate: _locateForPlace),
      ),
    );
    if (selected == null || !mounted || !repository.isCurrent) return;
    _selectSearchResult({
      'lat': selected.latitude.toString(),
      'lon': selected.longitude.toString(),
      'display_name': selected.name,
    });
  }

  @override
  Future<void> _savePersonalPlace(LatLng point) async {
    final repository = SavedPlacesRepository();
    final place = await showSavedPlaceEditor(context, point: point);
    if (place == null || !mounted) return;
    try {
      await repository.save(place);
      if (mounted) {
        _showSnackBar('Место сохранено в «Мои места» на этом устройстве');
      }
    } catch (_) {
      if (mounted) {
        _showSnackBar('Не удалось сохранить место. Данные не изменены.');
      }
    }
  }

  @override
  Future<void> _changeRouteWaypoints(List<LatLng> via) async {
    try {
      await _navigationController.replanWithWaypoints(via);
      _fitRoute();
    } catch (_) {
      _showSnackBar(
        'Не удалось изменить остановки. Предыдущий маршрут сохранён.',
      );
    }
  }

  @override
  Future<void> _openRoundTripPlanner() async {
    if (_navigationController.isLoadingRoute) return;
    final request = await showModalBottomSheet<RoundTripRequest>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          RoundTripPlanner(activity: _navigationController.selectedActivity),
    );
    if (request == null || !mounted) return;
    if (_navigationController.gpsSignal.value.updatedAt == null) {
      _showSnackBar('Дождитесь определения вашего местоположения');
      return;
    }
    _navigationController.setSelectedActivity(request.activity);
    try {
      await _navigationController.buildRoundTrip(
        distanceKm: request.distanceKm,
        bearing: request.bearing,
      );
      _fitRoute();
    } catch (error) {
      if (mounted) _showSnackBar('Не удалось построить круг: $error');
    }
  }

  void _fitRoute() {
    if (!mounted ||
        !_isMapReady ||
        _navigationController.routePoints.length < 2) {
      return;
    }
    _setCameraLockMode(CameraLockMode.free);
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(_navigationController.routePoints),
        padding: EdgeInsets.fromLTRB(
          24,
          200,
          24,
          MediaQuery.sizeOf(context).height * .48 + 24,
        ),
      ),
    );
  }

  Future<void> _loadSessionRoutes() async {
    try {
      await _repository.load();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) _showSnackBar('Не удалось прочитать маршруты: $error');
    }
  }

  /// Текущее поведение долгого нажатия (выделено из старого обработчика).
  @override
  void _setRouteTo(LatLng point) {
    _searchGeneration++;
    _searchDebounce?.cancel();
    FocusScope.of(context).unfocus();
    _navigationController.setFinishPoint(
      point,
      'Точка на карте (${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)})',
    );
    setState(() {
      _searchResults = [];
      _isChoosingRoute = false;
    });
    if (!_isMapReady) return;
    _mapController.move(point, _mapController.camera.zoom);
    _buildRoute();
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    final generation = ++_searchGeneration;
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    _searchDebounce = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _isSearching = true);
      try {
        if (_nearbySearch &&
            _navigationController.gpsSignal.value
                    .checkedAt(DateTime.now())
                    .quality ==
                GpsQuality.lost) {
          await _navigationController.initLocationTracking();
          if (!mounted || generation != _searchGeneration) return;
        }
        final signal = _navigationController.gpsSignal.value.checkedAt(
          DateTime.now(),
        );
        final center =
            signal.updatedAt != null &&
                signal.quality != GpsQuality.lost &&
                (signal.accuracy ?? double.infinity) <= 1000
            ? _navigationController.currentLocation
            : null;
        if (_nearbySearch && center == null) {
          if (mounted && generation == _searchGeneration) {
            setState(() => _isSearching = false);
            _showSnackBar('Уточните геопозицию или выберите поиск «Везде»');
          }
          return;
        }
        final service = GeocodingService();
        final results = await service.searchPlaces(
          query,
          center: center,
          nearbyOnly: _nearbySearch,
        );
        if (mounted && generation == _searchGeneration) {
          setState(() {
            _searchResults = results;
            _isSearching = false;
          });
          if (results.isEmpty)
            _showSnackBar(
              _nearbySearch
                  ? 'Рядом ничего не найдено. Уточните адрес или выберите «Везде».'
                  : 'Ничего не найдено. Уточните название или адрес.',
            );
          if (center != null) {
            final locality = await service.locality(center);
            if (mounted && generation == _searchGeneration) {
              setState(() => _searchLocality = locality);
            }
          }
        }
      } catch (_) {
        if (mounted && generation == _searchGeneration) {
          setState(() => _isSearching = false);
          _showSnackBar(
            'Не удалось выполнить поиск. Проверьте интернет и геопозицию.',
          );
        }
      }
    });
  }

  void _selectSearchResult(Map<String, dynamic> item) {
    _searchGeneration++;
    _searchDebounce?.cancel();
    final lat = double.parse(item['lat']);
    final lon = double.parse(item['lon']);
    final target = LatLng(lat, lon);

    _navigationController.setFinishPoint(
      target,
      item['display_name'] ?? 'Выбранное место',
    );
    setState(() {
      _searchResults = [];
      _searchController.text = item['display_name'] ?? '';
    });

    FocusScope.of(context).unfocus();
    if (!_isMapReady) return;
    _mapController.move(target, 14.0);
    _buildRoute();
  }

  Future<void> _buildRoute() async {
    if (_navigationController.finishPoint == null) return;
    if (_navigationController.gpsSignal.value.updatedAt == null) {
      _showSnackBar(
        'Дождитесь определения местоположения и нажмите «Повторить»',
      );
      return;
    }

    try {
      await _navigationController.buildRoute();
      _fitRoute();
    } catch (error) {
      if (mounted) _showSnackBar('Не удалось построить маршрут: $error');
    }
  }

  void _toggleBookmark() async {
    if (_navigationController.isBookmarked) {
      _navigationController.setBookmarked(false);
      _showSnackBar('Маршрут удален из сохраненных');
      return;
    }

    if (_navigationController.finishPoint == null ||
        _navigationController.routePoints.isEmpty) {
      return;
    }

    TextEditingController nameController = TextEditingController(
      text: _navigationController.finishAddress.contains('(')
          ? 'Маршрут ${_navigationController.finishAddress.split('(').first.trim()}'
          : _navigationController.finishAddress,
    );

    String? customName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Сохранить маршрут'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'Название маршрута',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepOrange,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );

    nameController.dispose();
    if (!mounted) return;
    if (customName != null && customName.isNotEmpty) {
      final surface = _navigationController.surfaceInfo;
      final newRoute = SavedRoute(
        createdAt: DateTime.now(),
        viaPoints: List.of(_navigationController.routeWaypoints),
        workoutDetails: WorkoutDetails(
          segmentStarts: _navigationController.routeSegmentStarts,
        ),
        navigationSteps: List.of(_navigationController.routeSteps),
        title: customName,
        distance:
            '${(_navigationController.routeDistanceKm ?? 0.0).toStringAsFixed(1)} км',
        duration: _navigationController.routeDurationMin != null
            ? _formatDuration(_navigationController.routeDurationMin!)
            : '0 мин',
        // Покрытие считал Overpass; если данных нет — честно пишем это.
        surfaceSummary: surface == null
            ? 'Покрытие: нет данных'
            : 'Асфальт: ${surface.asphaltPercent.round()}%, Гравий: ${surface.gravelPercent.round()}%',
        finishPoint: _navigationController.finishPoint!,
        routePoints: List.from(_navigationController.routePoints),
        activityType: _navigationController.selectedActivity,
      );
      // Единственное хранилище маршрутов — SavedRoutesRepository
      // (двойная запись в статический AppData удалена вместе с ним).
      try {
        await _repository.addRoute(newRoute);
        if (!mounted) return;
        _navigationController.setBookmarked(true);
        _showSnackBar('Маршрут успешно сохранен!');
      } catch (error) {
        if (mounted) _showSnackBar('Не удалось сохранить маршрут: $error');
      }
    }
  }

  void _toggleNavigation() {
    _navigationController.toggleNavigation();
    if (_navigationController.isNavigating) {
      _setCameraLockMode(CameraLockMode.followAndHeading);
      if (!_isMapReady) return;
      _mapController.moveAndRotate(
        _navigationController.currentLocation,
        17.5,
        // Единый источник угла — _currentHeading (см. _onCompassUpdate).
        -_currentHeading,
      );
    }
  }

  void _clearRoute() {
    _navigationController.clearRoute();
    _searchController.clear();
    setState(() {
      _searchResults = [];
    });
  }

  /// «Поделиться» маршрутом: копирует текст с параметрами и ссылкой на
  /// конечную точку (Google Maps) в буфер обмена.
  Future<void> _shareRoute() async {
    final finish = _navigationController.finishPoint;
    if (finish == null || _navigationController.routePoints.isEmpty) return;
    final route = SavedRoute(
      workoutDetails: WorkoutDetails(
        segmentStarts: _navigationController.routeSegmentStarts,
      ),
      title: _navigationController.finishAddress,
      distance: '${_navigationController.routeDistanceKm ?? 0} км',
      duration: '${(_navigationController.routeDurationMin ?? 0).round()} мин',
      surfaceSummary: '',
      finishPoint: finish,
      routePoints: List.of(_navigationController.routePoints),
      activityType: _navigationController.selectedActivity,
    );
    await showRouteShareSheet(
      context,
      SharedRoute.fromSavedRoute(route, kind: 'route'),
    );
  }

  /// Открытие сохранённых маршрутов с загрузкой выбранного маршрута на карту.
  @override
  Future<void> _openSavedRoutes() async {
    final SavedRoute? selectedRoute = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SavedRoutesScreen()),
    );
    if (selectedRoute == null) return;
    if (!mounted) return;
    _navigationController.loadSavedRoute(selectedRoute);
    _fitRoute();
  }

  String _formatDuration(double durationMin) {
    if (durationMin >= 60) {
      final hours = durationMin ~/ 60;
      final mins = (durationMin % 60).round();
      return '$hours ч $mins мин';
    }
    return '${durationMin.round()} мин';
  }

  String _formatETA(double durationMin) {
    final etaTime = DateTime.now().add(Duration(minutes: durationMin.round()));
    final hour = etaTime.hour.toString().padLeft(2, '0');
    final minute = etaTime.minute.toString().padLeft(2, '0');
    return 'до $hour:$minute';
  }

  int _calculateCalories() {
    if (_navigationController.routeDurationMin == null) return 0;
    final weight = context.read<ProfileProvider>().profile.weightKg;
    return _navigationController
        .routeCalories(_navigationController.routeDurationMin!, weight)
        .round();
  }
}
