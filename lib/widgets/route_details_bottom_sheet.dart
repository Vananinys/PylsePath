import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:url_launcher/url_launcher.dart';

import '../models/activity_type.dart';
import '../models/surface_info.dart';
import 'responsive_stats.dart';
import 'route_offline_readiness.dart';
import '../screens/offline_maps_screen.dart';
import '../screens/route_places_screen.dart';

class RouteDetailsBottomSheet extends StatelessWidget {
  final Future<void> Function(LatLng)? onAddPlaceStop;
  final double routeProgressMeters;
  final List<LatLng> routePoints;
  final bool hasOfflineInstructions;
  final DraggableScrollableController? sheetController;
  final Widget? gearAdvisor;
  final Widget? waypointEditor;
  final String finishAddress;
  final LatLng? finishPoint;
  final ActivityType selectedActivity;
  final List<ActivityType> activityTypes;
  final double? routeDistanceKm;
  final double? routeDurationMin;
  final int elevationGainMeters;
  final int elevationLossMeters;

  /// Покрытие из Overpass. `null` — данных нет: показываем честное «не удалось
  /// определить», а не проценты с потолка.
  final SurfaceInfo? surfaceInfo;
  final bool isLoadingRoute;
  final bool isBookmarked;
  final bool isNavigating;
  final String? routeError;
  final String? routeNotice;
  final VoidCallback? onRetry;
  final VoidCallback? onStartWorkout;
  final VoidCallback? onShowRoute;
  final VoidCallback? onRoundTrip;
  final bool hasRoute;
  final VoidCallback onClearRoute;
  final ValueChanged<ActivityType> onActivityChanged;
  final VoidCallback onToggleBookmark;
  final VoidCallback onToggleNavigation;
  final VoidCallback onShareRoute;
  final String Function(double) formatDuration;
  final String Function(double) formatETA;
  final int Function() calculateCalories;

  const RouteDetailsBottomSheet({
    this.onAddPlaceStop,
    this.routeProgressMeters = 0,
    this.routePoints = const [],
    this.hasOfflineInstructions = false,
    super.key,
    this.sheetController,
    this.gearAdvisor,
    this.waypointEditor,
    required this.finishAddress,
    required this.finishPoint,
    required this.selectedActivity,
    required this.activityTypes,
    required this.routeDistanceKm,
    required this.routeDurationMin,
    required this.elevationGainMeters,
    required this.elevationLossMeters,
    required this.surfaceInfo,
    required this.isLoadingRoute,
    required this.isBookmarked,
    required this.isNavigating,
    this.routeError,
    this.routeNotice,
    this.onRetry,
    this.onStartWorkout,
    this.onShowRoute,
    this.onRoundTrip,
    this.hasRoute = true,
    required this.onClearRoute,
    required this.onActivityChanged,
    required this.onToggleBookmark,
    required this.onToggleNavigation,
    required this.onShareRoute,
    required this.formatDuration,
    required this.formatETA,
    required this.calculateCalories,
  });

  Widget _buildStatCard(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
    required String subtitle,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: iconColor),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSurfaceLegend(BuildContext context, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// Секция покрытия: проценты, если данные есть, иначе честный «нет данных».
  Widget _buildSurfaceSection(BuildContext context) {
    final surface = surfaceInfo;
    if (surface == null) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text(
          'Покрытие: данных пока нет',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Типы покрытия:',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 10,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: surface.asphaltPercent.toInt() > 0
                      ? surface.asphaltPercent.toInt()
                      : 1,
                  child: const ColoredBox(color: Color(0xFF4F6D7A)),
                ),
                Expanded(
                  flex: surface.gravelPercent.toInt() > 0
                      ? surface.gravelPercent.toInt()
                      : 1,
                  child: const ColoredBox(color: Color(0xFFF4B400)),
                ),
                Expanded(
                  flex: surface.dirtPercent.toInt() > 0
                      ? surface.dirtPercent.toInt()
                      : 1,
                  child: const ColoredBox(color: Color(0xFF6D4C41)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: _buildSurfaceLegend(
                context,
                const Color(0xFF4F6D7A),
                'Асфальт ${surface.asphaltPercent.round()}%',
              ),
            ),
            Flexible(
              child: _buildSurfaceLegend(
                context,
                const Color(0xFFF4B400),
                'Гравий ${surface.gravelPercent.round()}%',
              ),
            ),
            Flexible(
              child: _buildSurfaceLegend(
                context,
                const Color(0xFF6D4C41),
                'Грунт ${surface.dirtPercent.round()}%',
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .48,
      minChildSize: .28,
      maxChildSize: .86,
      snap: true,
      snapSizes: const [.28, .48, .86],
      controller: sheetController,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 14,
              offset: Offset(0, -4),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  physics: const BouncingScrollPhysics(),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            width: 36,
                            height: 5,
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(2.5),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 2.0),
                              child: Icon(
                                Icons.location_on,
                                color: Colors.deepOrange,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    finishAddress.startsWith('Точка на карте')
                                        ? 'Точка назначения на карте'
                                        : finishAddress,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 17,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Откуда: моё местоположение',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Убрать маршрут с карты',
                              icon: Icon(
                                Icons.close,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                              onPressed: onClearRoute,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (!isLoadingRoute && hasRoute) ...[
                          ResponsiveStats(
                            children: [
                              _buildStatCard(
                                context,
                                icon: Icons.timer_outlined,
                                iconColor: const Color(0xFF2196F3),
                                title: 'Время',
                                value: routeDurationMin != null
                                    ? formatDuration(routeDurationMin!)
                                    : 'Нет данных',
                                subtitle: routeDurationMin != null
                                    ? formatETA(routeDurationMin!)
                                    : 'Время в пути',
                              ),
                              const SizedBox(width: 5),
                              _buildStatCard(
                                context,
                                icon: Icons.straighten_rounded,
                                iconColor: const Color(0xFFFF9800),
                                title: 'Дистанция',
                                value: routeDistanceKm == null
                                    ? 'Нет данных'
                                    : '${routeDistanceKm!.toStringAsFixed(1).replaceAll('.', ',')} км',
                                subtitle:
                                    '~${selectedActivity.avgSpeedKmH.round()} км/ч',
                              ),
                              const SizedBox(width: 5),
                              if (elevationGainMeters != 0 ||
                                  elevationLossMeters != 0)
                                _buildStatCard(
                                  context,
                                  icon: Icons.terrain_rounded,
                                  iconColor: const Color(0xFF4CAF50),
                                  title: 'Высота',
                                  value:
                                      elevationGainMeters == 0 &&
                                          elevationLossMeters == 0
                                      ? 'Нет данных'
                                      : '+$elevationGainMeters м',
                                  subtitle:
                                      elevationGainMeters == 0 &&
                                          elevationLossMeters == 0
                                      ? 'Нужны данные высоты'
                                      : '-$elevationLossMeters м',
                                ),
                              const SizedBox(width: 5),
                              _buildStatCard(
                                context,
                                icon: Icons.local_fire_department_outlined,
                                iconColor: const Color(0xFFFF5722),
                                title: 'Энергия',
                                value: '${calculateCalories()} ккал',
                                subtitle: 'оценка',
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (routeError != null)
                          Text(
                            routeError!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        if (routeNotice != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(
                              routeNotice!,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (hasRoute)
                          TextButton.icon(
                            icon: const Icon(Icons.local_cafe_outlined),
                            label: const Text('Вода и места по пути'),
                            onPressed: routePoints.length < 2
                                ? null
                                : () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => RoutePlacesScreen(
                                        points: List.of(routePoints),
                                        progressMeters: routeProgressMeters,
                                        onStop: onAddPlaceStop,
                                      ),
                                    ),
                                  ),
                          ),
                        if (hasRoute)
                          RouteOfflineReadiness(
                            routePoints: routePoints,
                            saved: isBookmarked,
                            hasGeometry: hasRoute,
                            hasInstructions: hasOfflineInstructions,
                            onSave: onToggleBookmark,
                            onOpenMaps: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => OfflineMapsScreen(
                                  currentLocation: finishPoint == null
                                      ? null
                                      : LatLngWithLabel(
                                          latitude: finishPoint!.latitude,
                                          longitude: finishPoint!.longitude,
                                          label: 'Финиш маршрута · область вокруг точки, не весь путь',
                                        ),
                                ),
                              ),
                            ),
                          ),
                        if (!selectedActivity.isFoot &&
                            selectedActivity != ActivityType.driving)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              'Предпочтения «тише», «меньше подъёмов» и «меньше остановок» пока не применяются к расчёту. Тип велосипеда используется для оценки темпа; отсутствие трафика и безопасность не гарантируются.',
                            ),
                          ),
                        if (elevationGainMeters == 0 &&
                            elevationLossMeters == 0)
                          const Text(
                            'Набор высоты не подтверждён. Нулевые значения не означают, что маршрут плоский.',
                          ),
                        ExpansionTile(
                          key: const PageStorageKey('route-activity'),
                          tilePadding: EdgeInsets.zero,
                          leading: Icon(selectedActivity.icon),
                          title: const Text('Как добраться'),
                          subtitle: Text(selectedActivity.label),
                          children: [
                            SizedBox(
                              height:
                                  32 +
                                  MediaQuery.textScalerOf(context).scale(20),
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: activityTypes.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, index) {
                                  final activity = activityTypes[index];
                                  final isSelected =
                                      selectedActivity == activity;
                                  return GestureDetector(
                                    onTap: () => onActivityChanged(activity),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? Colors.deepOrange
                                            : Theme.of(context)
                                                  .colorScheme
                                                  .surfaceContainerLow,
                                        borderRadius: BorderRadius.circular(14),
                                        border: isSelected
                                            ? null
                                            : Border.all(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .outlineVariant,
                                                width: 1,
                                              ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            activity.icon,
                                            size: 18,
                                            color: isSelected
                                                ? Colors.white
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .onSurface,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            activity.label,
                                            style: TextStyle(
                                              color: isSelected
                                                  ? Colors.white
                                                  : Theme.of(context)
                                                        .colorScheme
                                                        .onSurface,
                                              fontWeight: isSelected
                                                  ? FontWeight.bold
                                                  : FontWeight.w500,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                        if (waypointEditor != null)
                          ExpansionTile(
                            key: const PageStorageKey('route-stops'),
                            tilePadding: EdgeInsets.zero,
                            leading: const Icon(
                              Icons.add_location_alt_outlined,
                            ),
                            title: const Text('Остановки по пути'),
                            children: [waypointEditor!],
                          ),
                        ExpansionTile(
                          key: const PageStorageKey('route-more'),
                          tilePadding: EdgeInsets.zero,
                          leading: const Icon(Icons.more_horiz),
                          title: const Text('Ещё о маршруте'),
                          subtitle: const Text(
                            'Перестроить, весь маршрут, новый круг',
                          ),
                          children: [
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton.icon(
                                  onPressed: isLoadingRoute ? null : onRetry,
                                  icon: const Icon(Icons.refresh, size: 18),
                                  label: const Text('Повторить'),
                                ),
                                TextButton.icon(
                                  onPressed: hasRoute && !isLoadingRoute
                                      ? onShowRoute
                                      : null,
                                  icon: const Icon(
                                    Icons.zoom_out_map,
                                    size: 18,
                                  ),
                                  label: const Text('Весь маршрут'),
                                ),
                                TextButton.icon(
                                  onPressed: isLoadingRoute
                                      ? null
                                      : onRoundTrip,
                                  icon: const Icon(Icons.loop, size: 18),
                                  label: const Text('Новый круг'),
                                ),
                              ],
                            ),
                            _buildSurfaceSection(context),
                            if (gearAdvisor != null) gearAdvisor!,
                          ],
                        ),
                        const SizedBox(height: 14),
                        if (isLoadingRoute)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else ...[
                          const SizedBox(height: 16),
                          const SizedBox(height: 16),
                          TextButton(
                            onPressed: () => showModalBottomSheet<void>(
                              context: context,
                              builder: (_) => SafeArea(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Text(
                                        'О маршруте',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const Text(
                                        'Время и расход энергии — оценки. Данные высоты и покрытия показываются только при наличии источника.',
                                      ),
                                      TextButton(
                                        onPressed: () => launchUrl(
                                          Uri.parse(
                                            'https://routing.openstreetmap.de/about.html',
                                          ),
                                        ),
                                        child: const Text(
                                          'FOSSGIS — расчёт маршрутов',
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: () => launchUrl(
                                          Uri.parse(
                                            'https://www.openstreetmap.org/fixthemap',
                                          ),
                                        ),
                                        child: const Text(
                                          'Исправить OpenStreetMap',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            child: const Text(
                              '© OpenStreetMap · FOSSGIS ⓘ',
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Tooltip(
                          message: 'Сохранить маршрут',
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(54, 54),
                              padding: EdgeInsets.zero,
                              side: BorderSide(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant,
                                width: 1.5,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed: onToggleBookmark,
                            child: Icon(
                              isBookmarked
                                  ? Icons.bookmark
                                  : Icons.bookmark_border_rounded,
                              color: isBookmarked
                                  ? Colors.deepOrange
                                  : Theme.of(context).colorScheme.onSurface,
                              size: 24,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Tooltip(
                          message: 'Поделиться маршрутом',
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(54, 54),
                              padding: EdgeInsets.zero,
                              side: BorderSide(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant,
                                width: 1.5,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed: onShareRoute,
                            child: Icon(
                              Icons.share_outlined,
                              color: Theme.of(context).colorScheme.onSurface,
                              size: 24,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 54,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isNavigating
                                    ? Colors.grey.shade800
                                    : Colors.deepOrange,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                              onPressed: hasRoute && !isLoadingRoute
                                  ? (onStartWorkout ?? onToggleNavigation)
                                  : null,
                              icon: Transform.rotate(
                                angle: 45 * (3.1415926535 / 180),
                                child: Icon(
                                  isNavigating
                                      ? Icons.pause_circle_filled
                                      : Icons.navigation_rounded,
                                  size: 22,
                                ),
                              ),
                              label: Text(
                                onStartWorkout != null
                                    ? 'Начать тренировку'
                                    : (isNavigating
                                          ? 'Маршрут активен'
                                          : 'В путь'),
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    if (onStartWorkout != null)
                      TextButton.icon(
                        onPressed: hasRoute && !isLoadingRoute
                            ? onToggleNavigation
                            : null,
                        icon: const Icon(Icons.navigation_outlined, size: 18),
                        label: Text(
                          isNavigating
                              ? 'Остановить навигацию'
                              : 'Только навигация',
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
