import '../widgets/workout_analytics.dart';
import '../widgets/workout_comparison.dart';
import '../models/workout_details.dart';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../models/workout_record.dart';
import '../models/shared_route.dart';
import '../widgets/route_share_sheet.dart';
import '../utils/gpx_share.dart';
import '../widgets/community_feed.dart';
import '../data/navigation_preferences.dart';
import '../services/offline_maps_service.dart';
import '../widgets/ride_pulse_view.dart';
import '../widgets/ride_share_preview.dart';
import 'route_builder_screen.dart';
import 'ride_media_screen.dart';
import '../widgets/local_track_media_layer.dart';

class WorkoutDetailScreen extends StatelessWidget {
  final WorkoutRecord workout;
  final List<String> highlights;

  const WorkoutDetailScreen({
    super.key,
    required this.workout,
    this.highlights = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          workout.route.title.isNotEmpty
              ? workout.route.title
              : 'Детали заезда',
        ),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Отправить в чат',
            icon: const Icon(Icons.send_outlined),
            onPressed: () => showRouteShareSheet(
              context,
              SharedRoute.fromSavedRoute(workout.route),
              source: workout.route,
            ),
          ),
          // Экспорт трека в GPX: файл можно отправить в Strava/Komoot
          // или сохранить через системное меню «Поделиться».
          if (workout.route.routePoints.isNotEmpty)
            IconButton(
              tooltip: 'Экспорт GPX',
              icon: const Icon(Icons.file_download_outlined),
              onPressed: () => _exportGpx(context),
            ),
          IconButton(
            tooltip: 'Поделиться в сообществе',
            icon: const Icon(Icons.group_add_outlined),
            onPressed: () => _shareToCommunity(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Мини-карта с треком
            RidePulseView(
              route: workout.route,
              onExpandMap: () => _openMap(context),
            ),
            if (highlights.isNotEmpty)
              Card(
                margin: const EdgeInsets.all(16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '🏆 Новые личные результаты',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      for (final text in highlights)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(text),
                        ),
                    ],
                  ),
                ),
              ),
            // Сетка метрик
            _buildMetricsGrid(context),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: FilledButton.icon(
                icon: const Icon(Icons.add_photo_alternate),
                label: const Text('Фото и видео на треке'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RideMediaScreen(
                      rideId: workout.route.localId,
                      points: workout.route.routePoints,
                      segmentStarts: workout.route.workoutDetails.segmentStarts,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.edit_road),
                label: const Text('Создать маршрут из этого трека'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RouteBuilderScreen(source: workout.route),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.image_outlined),
                label: const Text('Поделиться карточкой заезда'),
                onPressed: () => _shareCard(context),
              ),
            ),
            // Дополнительная информация
            WorkoutAnalytics(route: workout.route),
            WorkoutComparison(route: workout.route),
            _buildAdditionalInfo(),
          ],
        ),
      ),
    );
  }

  Future<void> _shareToCommunity(BuildContext context) async {
    final published = await showCommunityComposer(
      context,
      route: workout.route,
    );
    if (published && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Опубликовано в сообществе')),
      );
    }
  }

  Future<void> _shareCard(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => RideSharePreview(
      activityType: workout.route.activityType.label,
      distanceMeters: workout.route.distanceKm * 1000,
      durationSeconds: workout.route.durationMin * 60,
      // Legacy zero means unknown, not a measured flat ride.
      elevationGainMeters:
          workout.elevationGain.isFinite && workout.elevationGain > 0
          ? workout.elevationGain
          : null,
    ),
  );

  Future<void> _openMap(BuildContext context) => showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.sizeOf(dialogContext).height * .8,
        child: Column(
          children: [
            Row(
              children: [
                const SizedBox(width: 16),
                const Expanded(child: Text('Карта заезда')),
                IconButton(
                  tooltip: 'Закрыть карту',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(dialogContext),
                ),
              ],
            ),
            Expanded(child: _buildMapPreview(context)),
          ],
        ),
      ),
    ),
  );

  Future<void> _exportGpx(BuildContext context) async {
    try {
      await GpxShare.route(context, workout.route);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось подготовить GPX-файл')),
        );
      }
    }
  }

  Widget _buildMapPreview(BuildContext context) {
    final points = workout.route.routePoints;
    if (points.isEmpty) {
      return Container(
        height: 200,
        color: Colors.grey[200],
        child: const Center(child: Text('Трек недоступен')),
      );
    }

    // Вписываем трек в видимую область карты целиком.
    final bounds = LatLngBounds.fromPoints(points);

    return Container(
      height: 250,
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FlutterMap(
          options: MapOptions(
            initialCenter: points.first,
            initialZoom: 16,
            initialCameraFit: points.length > 1
                ? CameraFit.bounds(
                    bounds: bounds,
                    padding: const EdgeInsets.all(24),
                    maxZoom: 17,
                  )
                : null,
          ),
          children: [
            if (!NavigationPreferences.instance.cachedMapOnly ||
                OfflineMapsService.isAvailable)
              TileLayer(
                urlTemplate: OfflineMapsService.routeTileUrl,
                tileProvider: OfflineMapsService.tileProvider(
                  offlineOnly: NavigationPreferences.instance.cachedMapOnly,
                ),
                userAgentPackageName: 'com.pulsepath.app',
              ),
            PolylineLayer(
              polylines: [
                for (final segment in WorkoutDetails.splitTrack(
                  points,
                  workout.route.workoutDetails.segmentStarts,
                ))
                  Polyline(
                    points: segment,
                    color: Colors.deepOrange.withValues(alpha: 0.8),
                    strokeWidth: 4,
                  ),
              ],
            ),
            MarkerLayer(
              markers: [
                if (points.isNotEmpty)
                  Marker(
                    point: points.first,
                    width: 20,
                    height: 20,
                    child: const Icon(
                      Icons.location_on,
                      color: Colors.green,
                      size: 20,
                    ),
                  ),
                if (points.length > 1)
                  Marker(
                    point: points.last,
                    width: 20,
                    height: 20,
                    child: const Icon(Icons.flag, color: Colors.red, size: 20),
                  ),
              ],
            ),
            LocalTrackMediaLayer(
              rideId: workout.route.localId,
              points: points,
              onOpen: (item) async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RideMediaScreen(
                      rideId: workout.route.localId,
                      points: points,
                      segmentStarts: workout.route.workoutDetails.segmentStarts,
                      initialMediaId: item.id,
                      initialIndex: item.pointIndex,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricsGrid(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: GridView.extent(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        maxCrossAxisExtent: 240,
        childAspectRatio: 1.1 / MediaQuery.textScalerOf(context).scale(1),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        children: [
          _buildMetricCard(
            title: 'Дистанция',
            value: workout.route.distance,
            icon: Icons.straighten,
            color: Colors.blue,
          ),
          _buildMetricCard(
            title: 'Время движения',
            value: workout.route.displayDuration,
            icon: Icons.timer,
            color: Colors.orange,
          ),
          _buildMetricCard(
            title: 'Средняя скорость',
            value: '${workout.averageSpeed.toStringAsFixed(1)} км/ч',
            icon: Icons.speed,
            color: Colors.green,
          ),
          _buildMetricCard(
            title: 'Максимальная скорость',
            value:
                workout.maxSpeed > 0 ||
                    workout.route.workoutDetails.samples.any(
                      (s) => s.speedKmh != null,
                    )
                ? '${workout.maxSpeed.toStringAsFixed(1)} км/ч'
                : 'Нет данных',
            icon: Icons.flash_on,
            color: Colors.red,
          ),
          _buildMetricCard(
            title: 'Набор высоты',
            value: workout.elevationGain > 0
                ? '${workout.elevationGain.toStringAsFixed(0)} м'
                : 'Нет данных',
            icon: Icons.terrain,
            color: Colors.purple,
          ),
          _buildMetricCard(
            title: 'Энергия · оценка',
            value: workout.route.calories > 0
                ? '${workout.route.calories.round()} ккал'
                : 'Нет данных',
            icon: Icons.local_fire_department_outlined,
            color: Colors.orange,
          ),
          _buildMetricCard(
            title: 'Средняя с остановками',
            value: workout.route.workoutDetails.elapsedSeconds > 0
                ? '${(workout.route.distanceKm * 3600 / workout.route.workoutDetails.elapsedSeconds).toStringAsFixed(1)} км/ч'
                : 'Нет данных',
            icon: Icons.av_timer,
            color: Colors.blueGrey,
          ),
          _buildMetricCard(
            title: 'Тип активности',
            value: workout.route.activityType.label,
            icon: Icons.directions_bike,
            color: Colors.deepOrange,
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdditionalInfo() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Дополнительная информация',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.date_range, size: 18, color: Colors.grey),
              const SizedBox(width: 8),
              Text(
                'Дата: ${_formatDate(workout.timestamp)}',
                style: const TextStyle(fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.landscape, size: 18, color: Colors.grey),
              const SizedBox(width: 8),
              Text(
                'Покрытие: ${workout.route.surfaceSummary}',
                style: const TextStyle(fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.location_on, size: 18, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Точек трека: ${workout.route.routePoints.length}',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}.${date.month}.${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}
