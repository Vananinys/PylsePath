part of '../../main.dart';

/// Городской модуль: метки проблем, отчёты, слой парковок.
mixin _UrbanMapMixin on _MapScreenStateBase {
  /// Загружает метки видимой области и подписывается на realtime.
  /// Вызывается после готовности карты; повторные вызовы безопасны.
  Future<void> _refreshMapMarks() async {
    if (!MapMarksService.isAvailable) return;
    final bounds = _mapController.camera.visibleBounds;
    final marks = await _mapMarksService.fetchVisible(
      bounds.south,
      bounds.west,
      bounds.north,
      bounds.east,
    );
    if (!mounted) return;
    setState(() {
      _mapMarks
        ..clear()
        ..addAll(marks);
    });
  }

  Future<void> _subscribeMapMarks() async {
    if (!MapMarksService.isAvailable) return;
    await _mapMarksService.subscribe(
      (mark) {
        if (!mounted) return;
        setState(() {
          _mapMarks.removeWhere((existing) => existing.id == mark.id);
          _mapMarks.add(mark);
        });
      },
      (markId) {
        if (!mounted) return;
        setState(
          () => _mapMarks.removeWhere((existing) => existing.id == markId),
        );
      },
    );
  }

  /// Долгое нажатие → контекстное меню: маршрут сюда / сообщить о проблеме.
  Future<void> _showMapContextMenu(LatLng point) async {
    final urbanEnabled = context.read<ProfileProvider>().isModuleEnabled(
      UiModules.urban,
    );
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.route, color: Colors.deepOrange),
              title: const Text('Маршрут сюда'),
              subtitle: Text(
                '${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}',
              ),
              onTap: () => Navigator.pop(sheetContext, 'route'),
            ),
            if (urbanEnabled)
              ListTile(
                leading: const Icon(Icons.report_problem, color: Colors.amber),
                title: const Text('Сообщить о проблеме'),
                subtitle: const Text('Яма, собаки, парковка, ремонт'),
                onTap: () => Navigator.pop(sheetContext, 'report'),
              ),
            if (_navigationController.canEditWaypoints &&
                _navigationController.routeWaypoints.length < 8)
              ListTile(
                leading: const Icon(
                  Icons.add_location_alt_outlined,
                  color: Colors.deepOrange,
                ),
                title: const Text('Добавить остановку'),
                subtitle: const Text('Перед финишем текущего маршрута'),
                onTap: () => Navigator.pop(sheetContext, 'waypoint'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'route':
        _setRouteTo(point);
      case 'report':
        _openReportSheet(point);
      case 'waypoint':
        await _changeRouteWaypoints([
          ..._navigationController.routeWaypoints,
          point,
        ]);
    }
  }

  /// Выбор типа проблемы и создание метки.
  Future<void> _openReportSheet(LatLng point) async {
    setState(() => _pendingReportPoint = point);
    final type = await showModalBottomSheet<MarkType>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Что здесь?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            for (final type in MarkType.values)
              ListTile(
                leading: Text(type.emoji, style: const TextStyle(fontSize: 28)),
                title: Text(type.label),
                onTap: () => Navigator.pop(sheetContext, type),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _pendingReportPoint = null);
    if (type == null) return;
    final mark = await _mapMarksService.create(point, type);
    if (!mounted) return;
    if (mark == null) {
      _showSnackBar('Не удалось создать метку. Проверьте интернет.');
      return;
    }
    setState(() {
      _mapMarks.removeWhere((existing) => existing.id == mark.id);
      _mapMarks.add(mark);
    });
    _showSnackBar('Спасибо! Метка «${type.label}» появится у всех райдеров.');
  }

  /// Инфо о метке + удаление своей.
  Future<void> _showMarkDetails(MapMark mark) async {
    final currentUserId = _mapMarksService.userId;
    final isMine = mark.authorId == currentUserId;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Text(
                mark.type.emoji,
                style: const TextStyle(fontSize: 30),
              ),
              title: Text(mark.type.label),
              subtitle: Text('Осталась видна ${_markRemaining(mark)}'),
            ),
            if (isMine)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Убрать метку'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final ok = await _mapMarksService.delete(mark.id);
                  if (!mounted) return;
                  if (ok) {
                    setState(
                      () => _mapMarks.removeWhere((m) => m.id == mark.id),
                    );
                  } else {
                    _showSnackBar('Не удалось убрать метку');
                  }
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  static String _markRemaining(MapMark mark) {
    final left = mark.expiresAt.difference(DateTime.now());
    if (left.isNegative) return 'истекает…';
    if (left.inHours < 1) return '${left.inMinutes} мин';
    if (left.inHours < 48) return '${left.inHours} ч';
    return '${left.inDays} дн.';
  }

  void _toggleParkingLayer() {
    setState(() => _showParkingLayer = !_showParkingLayer);
    if (_showParkingLayer) {
      _parkingsDebounce?.cancel();
      _parkingsDebounce = Timer(const Duration(milliseconds: 300), () {
        unawaited(_loadParkingsForViewport());
      });
    }
  }

  /// Загружает парковки видимой области; повторные области кэшируются.
  /// Разбиение на регионы ~0.05° не даёт Overpass-запросам взрываться.
  Future<void> _loadParkingsForViewport() async {
    if (!_showParkingLayer || _parkingsLoading || !_isMapReady) return;
    final bounds = _mapController.camera.visibleBounds;
    // Округляем к сетке: одинаковые области не запрашиваются повторно.
    final region =
        '${(bounds.south * 20).floor()}:${(bounds.west * 20).floor()}'
        ':${(bounds.north * 20).ceil()}:${(bounds.east * 20).ceil()}';
    if (_parkingsLoadedRegions.contains(region)) return;
    _parkingsLoading = true;
    try {
      final found = await _overpassService.fetchParkings(
        south: bounds.south,
        west: bounds.west,
        north: bounds.north,
        east: bounds.east,
      );
      _parkingsLoadedRegions.add(region);
      if (mounted) {
        setState(() {
          for (final p in found) {
            if (!_parkings.any(
              (existing) =>
                  existing.point.latitude == p.point.latitude &&
                  existing.point.longitude == p.point.longitude,
            )) {
              _parkings.add(p);
            }
          }
        });
      }
    } finally {
      _parkingsLoading = false;
    }
  }

  void _onLongPressMap(LatLng point) {
    _searchGeneration++;
    _searchDebounce?.cancel();
    if (_isScreenLocked) return;
    FocusScope.of(context).unfocus();
    unawaited(_showMapContextMenu(point));
  }
}
