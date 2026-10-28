import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:flutter_map/flutter_map.dart';

import '../models/route_step.dart';
import '../services/weather_service.dart';

class MapWeatherPill extends StatelessWidget {
  const MapWeatherPill({
    super.key,
    required this.weather,
    required this.isLoading,
    required this.onTap,
  });

  final WeatherInfo? weather;
  final bool isLoading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    elevation: 2,
    color: Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      onTap: isLoading ? null : onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading)
              const SizedBox.square(
                dimension: 17,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                weather?.icon ?? Icons.cloud_outlined,
                size: 18,
                color: Colors.blueGrey,
              ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                isLoading
                    ? 'Погода…'
                    : weather?.temperatureC != null
                    ? '${weather!.temperatureC!.round()}° · ${weather!.label}'
                    : 'Погода',
                style: Theme.of(context).textTheme.labelMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class SearchPanel extends StatefulWidget {
  final FocusNode? focusNode;
  final TextEditingController searchController;
  final bool isSearching;
  final List<Map<String, dynamic>> searchResults;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<Map<String, dynamic>> onSelectResult;
  final VoidCallback onClearSearch;
  final VoidCallback openDrawer;
  final ValueChanged<String>? onSearchSubmitted;
  final ValueChanged<bool>? onSearchScopeChanged;
  final bool nearbyOnly;
  final String? locality;

  const SearchPanel({
    super.key,
    required this.searchController,
    required this.isSearching,
    required this.searchResults,
    required this.onSearchChanged,
    required this.onSelectResult,
    required this.onClearSearch,
    required this.openDrawer,
    this.focusNode,
    this.onSearchSubmitted,
    this.onSearchScopeChanged,
    this.nearbyOnly = true,
    this.locality,
  });

  @override
  State<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<SearchPanel> {
  bool _focused = false;
  bool _scopeOpen = false;
  TextEditingController get searchController => widget.searchController;
  bool get isSearching => widget.isSearching;
  List<Map<String, dynamic>> get searchResults => widget.searchResults;
  ValueChanged<String> get onSearchChanged => widget.onSearchChanged;
  ValueChanged<Map<String, dynamic>> get onSelectResult =>
      widget.onSelectResult;
  VoidCallback get onClearSearch => widget.onClearSearch;
  VoidCallback get openDrawer => widget.openDrawer;
  ValueChanged<String>? get onSearchSubmitted => widget.onSearchSubmitted;
  ValueChanged<bool>? get onSearchScopeChanged => widget.onSearchScopeChanged;
  bool get nearbyOnly => widget.nearbyOnly;
  String? get locality => widget.locality;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Card(
                elevation: 4,
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: searchController,
                      focusNode: widget.focusNode,
                      onChanged: onSearchChanged,
                      onSubmitted: onSearchSubmitted,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Куда направимся?',
                        prefixIcon: Builder(
                          builder: (context) => IconButton(
                            icon: const Icon(Icons.menu),
                            onPressed: openDrawer,
                          ),
                        ),
                        suffixIcon: isSearching
                            ? const Padding(
                                padding: EdgeInsets.all(12.0),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : (searchController.text.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.clear),
                                      onPressed: onClearSearch,
                                    )
                                  : null),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                    if (_focused ||
                        _scopeOpen ||
                        isSearching ||
                        searchResults.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.near_me_outlined,
                              size: 15,
                              color: Colors.deepOrange,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                nearbyOnly
                                    ? locality ?? 'Рядом с вами · до 25 км'
                                    : 'Поиск в любом городе',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black54,
                                ),
                              ),
                            ),
                            PopupMenuButton<bool>(
                              tooltip: 'Где искать',
                              initialValue: nearbyOnly,
                              onOpened: () => setState(() => _scopeOpen = true),
                              onCanceled: () =>
                                  setState(() => _scopeOpen = false),
                              onSelected: (value) {
                                onSearchScopeChanged?.call(value);
                                setState(() => _scopeOpen = false);
                              },
                              itemBuilder: (_) => [
                                CheckedPopupMenuItem(
                                  value: true,
                                  checked: nearbyOnly,
                                  child: const Text('Рядом'),
                                ),
                                CheckedPopupMenuItem(
                                  value: false,
                                  checked: !nearbyOnly,
                                  child: const Text('Везде'),
                                ),
                              ],
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(nearbyOnly ? 'Рядом' : 'Везде'),
                                    const Icon(Icons.expand_more, size: 18),
                                  ],
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Найти место',
                              onPressed: isSearching
                                  ? null
                                  : () => onSearchSubmitted?.call(
                                      searchController.text,
                                    ),
                              icon: const Icon(Icons.search),
                            ),
                          ],
                        ),
                      ),
                    if (searchResults.isNotEmpty) const Divider(height: 1),
                    if (searchResults.isNotEmpty)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight:
                              (MediaQuery.sizeOf(context).height -
                                      MediaQuery.viewInsetsOf(context).bottom -
                                      MediaQuery.paddingOf(context).top -
                                      170)
                                  .clamp(64, 240),
                        ),
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: searchResults.length,
                          itemBuilder: (context, index) {
                            final item = searchResults[index];
                            return ListTile(
                              dense: true,
                              title: Text(
                                item['display_name'] ?? '',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => onSelectResult(item),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NavigationCard extends StatelessWidget {
  final bool offRoute;
  final bool preserveTrack;
  final double deviationMeters;
  final RouteStep? activeStep;
  final double? distanceToNextStepMeters;
  final double remainingMeters;
  final double remainingMinutes;
  final bool isRerouting;

  const NavigationCard({
    this.offRoute = false,
    this.preserveTrack = false,
    this.deviationMeters = 0,
    super.key,
    required this.activeStep,
    required this.distanceToNextStepMeters,
    this.remainingMeters = 0,
    this.remainingMinutes = 0,
    this.isRerouting = false,
  });

  @override
  Widget build(BuildContext context) {
    if (activeStep == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10.0),
      child: Card(
        color: Colors.black87,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Row(
            children: [
              Icon(
                offRoute ? Icons.wrong_location_outlined : activeStep!.icon,
                color: offRoute ? Colors.orangeAccent : Colors.greenAccent,
                size: 36,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      offRoute
                          ? 'В стороне от маршрута · ${deviationMeters.round()} м'
                          : distanceToNextStepMeters != null
                          ? 'Через ${distanceToNextStepMeters!.round()} м'
                          : 'Следующий маневр',
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      offRoute
                          ? (preserveTrack
                                ? 'Вернитесь к сохранённому треку'
                                : 'Проверьте путь на карте')
                          : activeStep!.instruction,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isRerouting
                          ? 'Перестраиваем маршрут…'
                          : 'До финиша ${(remainingMeters / 1000).toStringAsFixed(1).replaceAll('.', ',')} км · ≈${_remainingTime(remainingMinutes)}',
                      maxLines: 2,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _remainingTime(double minutes) {
  final rounded = minutes.ceil();
  return rounded >= 60
      ? '${rounded ~/ 60} ч ${rounded % 60} мин'
      : '$rounded мин';
}

class MapOverlays extends StatelessWidget {
  final MapController mapController;
  final bool autoRotateMap;
  final bool isFollowingUser;
  final bool isWorkoutActive;
  final bool isWorkoutPaused;
  final double currentHeading;
  final LatLng currentLocation;
  final ValueChanged<bool> onAutoRotateChanged;
  final VoidCallback onFollowUser;
  final double bottomOffset;
  // Режим камеры и компас
  final String cameraLockModeLabel;
  final IconData cameraLockModeIcon;
  final VoidCallback onCameraLockModePressed;
  final double mapRotation; // угол поворота карты в градусах
  final VoidCallback onCompassPressed;
  // Блокировка экрана (защита от случайных нажатий)
  final bool isScreenLocked;
  final VoidCallback onLockScreen;
  final VoidCallback onScreenUnlocked;
  // Переключение слоя карты
  final String mapLayerLabel;
  final VoidCallback onMapLayerPressed;
  // Слой парковок (городской модуль); null — кнопка скрыта.
  final bool? showParkingLayer;
  final VoidCallback? onParkingLayerPressed;

  const MapOverlays({
    super.key,
    required this.mapController,
    required this.autoRotateMap,
    required this.isFollowingUser,
    required this.isWorkoutActive,
    required this.isWorkoutPaused,
    required this.currentHeading,
    required this.currentLocation,
    required this.onAutoRotateChanged,
    required this.onFollowUser,
    this.bottomOffset = 20,
    required this.cameraLockModeLabel,
    required this.cameraLockModeIcon,
    required this.onCameraLockModePressed,
    required this.mapRotation,
    required this.onCompassPressed,
    this.isScreenLocked = false,
    required this.onLockScreen,
    required this.onScreenUnlocked,
    required this.mapLayerLabel,
    required this.onMapLayerPressed,
    this.showParkingLayer,
    this.onParkingLayerPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final available =
        (MediaQuery.sizeOf(context).height -
                MediaQuery.paddingOf(context).top -
                140 -
                bottomOffset)
            .clamp(56.0, double.infinity);
    return Positioned(
      right: 12,
      bottom: bottomOffset,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: available),
        child: Material(
          elevation: 5,
          shadowColor: Colors.black26,
          color: colors.surface,
          borderRadius: BorderRadius.circular(26),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _panelButton(
                  icon: isFollowingUser ? Icons.navigation : Icons.my_location,
                  tooltip: 'Моя геопозиция',
                  background: isFollowingUser
                      ? colors.primaryContainer
                      : colors.surface,
                  foreground: colors.onSurface,
                  onPressed: isScreenLocked ? null : onFollowUser,
                ),
                _panelGap(),
                _panelButton(
                  icon: Icons.tune,
                  tooltip: 'Инструменты карты',
                  background: colors.surface,
                  foreground: colors.onSurface,
                  onPressed: isScreenLocked ? null : () => _showTools(context),
                ),
                _panelGap(),
                if (isWorkoutActive || isWorkoutPaused || isScreenLocked)
                  LockButton(
                    isLocked: isScreenLocked,
                    onLock: onLockScreen,
                    onUnlocked: onScreenUnlocked,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showTools(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (c) => SingleChildScrollView(
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Инструменты карты',
                    style: Theme.of(c).textTheme.titleLarge,
                  ),
                ),
                ListTile(
                  leading: Icon(cameraLockModeIcon),
                  title: const Text('Режим камеры'),
                  subtitle: Text(cameraLockModeLabel),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.pop(c);
                    onCameraLockModePressed();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.explore_outlined),
                  title: const Text('Север сверху'),
                  subtitle: Text('Сейчас поворот ${(-mapRotation).round()}°'),
                  onTap: () {
                    Navigator.pop(c);
                    onCompassPressed();
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.navigation_outlined),
                  title: const Text('Поворачивать по направлению движения'),
                  value: autoRotateMap,
                  onChanged: (value) {
                    Navigator.pop(c);
                    onAutoRotateChanged(value);
                    if (!value) mapController.rotate(0);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.layers_outlined),
                  title: const Text('Слой карты'),
                  subtitle: Text(mapLayerLabel),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.pop(c);
                    onMapLayerPressed();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('Заблокировать экран'),
                  onTap: () {
                    Navigator.pop(c);
                    onLockScreen();
                  },
                ),
                if (showParkingLayer != null && onParkingLayerPressed != null)
                  SwitchListTile(
                    secondary: const Icon(Icons.local_parking_outlined),
                    title: const Text('Парковки'),
                    value: showParkingLayer!,
                    onChanged: (_) {
                      Navigator.pop(c);
                      onParkingLayerPressed!();
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _panelGap() => const SizedBox(height: 4);

  /// Круглая кнопка внутри панели. `onPressed == null` — заблокирована
  /// (блокировка экрана), подсветка приглушается.
  Widget _panelButton({
    IconData? icon,
    Widget? custom,
    required String tooltip,
    required Color background,
    Color foreground = Colors.white,
    VoidCallback? onPressed,
  }) {
    final bool disabled = onPressed == null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: disabled ? Colors.white24 : background,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: custom ?? Icon(icon, size: 20, color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}

/// Кнопка блокировки экрана.
///
/// Короткий тап (когда экран не заблокирован) — блокирует. Разблокировка —
/// только удержание 1.5 секунды: случайное касание в кармане блокировку
/// не поднимет. GestureDetector.onLongPressStart срабатывает примерно через
/// 500 мс, дальше держит таймер до полных 1.5 с.
class LockButton extends StatefulWidget {
  final bool isLocked;
  final VoidCallback onLock;
  final VoidCallback onUnlocked;

  const LockButton({
    super.key,
    required this.isLocked,
    required this.onLock,
    required this.onUnlocked,
  });

  @override
  State<LockButton> createState() => _LockButtonState();
}

class _LockButtonState extends State<LockButton> {
  static const Duration _holdDuration = Duration(milliseconds: 1500);
  Timer? _holdTimer;
  bool _holding = false;

  void _startHold(LongPressStartDetails _) {
    if (!widget.isLocked) return;
    setState(() => _holding = true);
    _holdTimer?.cancel();
    _holdTimer = Timer(_holdDuration, () {
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() => _holding = false);
      widget.onUnlocked();
    });
  }

  void _cancelHold([LongPressEndDetails? _]) {
    _holdTimer?.cancel();
    if (_holding && mounted) setState(() => _holding = false);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.isLocked
          ? 'Удерживайте 1.5 сек для разблокировки'
          : 'Блокировка экрана',
      child: GestureDetector(
        onLongPressStart: _startHold,
        onLongPressEnd: _cancelHold,
        onLongPressCancel: () => _cancelHold(),
        onTap: widget.isLocked ? null : widget.onLock,
        child: Material(
          color: widget.isLocked ? Colors.redAccent : Colors.white24,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          elevation: _holding ? 6 : 0,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Center(
              child: AnimatedScale(
                scale: _holding ? 1.25 : 1.0,
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  widget.isLocked ? Icons.lock : Icons.lock_open,
                  size: 20,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
