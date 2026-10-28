import 'activity_trail_layer.dart';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../models/shared_route.dart';
import '../data/saved_routes_repository.dart';
import '../data/navigation_preferences.dart';
import '../services/offline_maps_service.dart';
import '../models/ride_media.dart';
import 'shared_ride_media_viewer.dart';
import 'track_media_thumbnail.dart';
import '../models/track_media_groups.dart';

class SharedRouteCard extends StatelessWidget {
  const SharedRouteCard({super.key, required this.route, this.tileProvider});
  final SharedRoute route;
  final TileProvider? tileProvider;
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: () => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SharedRouteScreen(route: route)),
    ),
    child: Container(
      constraints: const BoxConstraints(minWidth: 180),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (route.points.length >= 2)
            SizedBox(
              height: 118,
              width: double.infinity,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(14),
                ),
                child: IgnorePointer(
                  child: FlutterMap(
                    options: MapOptions(
                      initialCameraFit: CameraFit.bounds(
                        bounds: LatLngBounds.fromPoints(route.points),
                        padding: const EdgeInsets.all(18),
                        maxZoom: 16,
                      ),
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.none,
                      ),
                    ),
                    children: [
                      if (tileProvider != null ||
                          !NavigationPreferences.instance.cachedMapOnly ||
                          OfflineMapsService.isAvailable)
                        TileLayer(
                          tileProvider:
                              tileProvider ??
                              OfflineMapsService.tileProvider(
                                offlineOnly: NavigationPreferences
                                    .instance
                                    .cachedMapOnly,
                              ),
                          urlTemplate: OfflineMapsService.routeTileUrl,
                          userAgentPackageName: 'com.pulsepath.app',
                        ),
                      PolylineLayer(
                        polylines: [
                          for (final segment in route.segments)
                            Polyline(
                              points: segment,
                              color: Colors.deepOrange,
                              strokeWidth: 3.5,
                              borderStrokeWidth: 1.5,
                              borderColor: Colors.white,
                            ),
                        ],
                      ),
                      const Align(
                        alignment: Alignment.bottomRight,
                        child: ColoredBox(
                          color: Colors.white70,
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 3),
                            child: Text(
                              '© OpenStreetMap',
                              style: TextStyle(
                                fontSize: 9,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${route.label} · ${route.activity.label}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                Text(
                  route.title.isEmpty ? route.label : route.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  '${route.distanceKm.toStringAsFixed(1)} км · ${route.durationSeconds ~/ 60} мин',
                ),
                const SizedBox(height: 4),
                const Text('Открыть →', style: TextStyle(fontSize: 12)),
                if (route.media.isNotEmpty)
                  Text('Фото и видео на карте · ${route.media.length}'),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class SharedRouteScreen extends StatefulWidget {
  const SharedRouteScreen({super.key, required this.route});
  final SharedRoute route;
  @override
  State<SharedRouteScreen> createState() => _SharedRouteScreenState();
}

class _SharedRouteScreenState extends State<SharedRouteScreen> {
  SharedRoute get route => widget.route;
  final _map = MapController();
  bool _ready = false;
  double _zoom = 15;
  String? _selectedId;
  void _select(SharedRideMedia item) {
    setState(() => _selectedId = item.id);
    if (_ready && item.pointIndex < route.points.length) {
      _map.move(route.points[item.pointIndex], _zoom < 16 ? 16 : _zoom);
    }
  }

  void _group(List<SharedRideMedia> items) {
    if (items.length == 1) {
      _select(items.first);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('${items.length} материалов в этом месте'),
            ),
            TrackMediaStrip(
              shared: items,
              onSelect: (id) {
                Navigator.pop(sheet);
                _select(items.firstWhere((m) => m.id == id));
              },
              onOpen: (id) {
                Navigator.pop(sheet);
                final item = items.firstWhere((m) => m.id == id);
                _select(item);
                _open(item);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  void _open(SharedRideMedia media) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => SharedRideMediaViewer(media: media)),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(route.title.isEmpty ? route.label : route.title),
    ),
    body: Column(
      children: [
        Expanded(
          child: route.points.length < 2
              ? const Center(
                  child: Text('Статистика заезда · трек не прикреплён'),
                )
              : FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    onMapReady: () => _ready = true,
                    onPositionChanged: (camera, _) {
                      if ((camera.zoom - _zoom).abs() > .25 && mounted) {
                        setState(() => _zoom = camera.zoom);
                      }
                    },
                    initialCameraFit: CameraFit.bounds(
                      bounds: LatLngBounds.fromPoints(route.points),
                      padding: const EdgeInsets.all(40),
                    ),
                  ),
                  children: [
                    if (!NavigationPreferences.instance.cachedMapOnly ||
                        OfflineMapsService.isAvailable)
                      TileLayer(
                        tileProvider: OfflineMapsService.tileProvider(
                          offlineOnly:
                              NavigationPreferences.instance.cachedMapOnly,
                        ),
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.pulsepath.app',
                      ),
                    ActivityTrailLayer(
                      segments: route.segments,
                      activity: route.activity,
                    ),
                    const RichAttributionWidget(
                      attributions: [
                        TextSourceAttribution('© OpenStreetMap contributors'),
                      ],
                    ),
                    MarkerLayer(
                      markers: [
                        for (final group in groupTrackMedia(
                          route.media,
                          route.points,
                          (item) => item.pointIndex,
                          _zoom,
                        ))
                          Marker(
                            point: route.points[group.first.pointIndex],
                            width: 60,
                            height: 60,
                            child: TrackMediaThumbnail(
                              shared: group.first,
                              count: group.length,
                              selected: group.any((m) => m.id == _selectedId),
                              onTap: () => _group(group),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
        ),
        if (route.media.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              '${route.media.length} материалов · миниатюра показывает место',
            ),
          ),
          TrackMediaStrip(
            shared: route.media,
            selectedId: _selectedId,
            onSelect: (id) =>
                _select(route.media.firstWhere((m) => m.id == id)),
            onOpen: (id) {
              final item = route.media.firstWhere((m) => m.id == id);
              _select(item);
              _open(item);
            },
          ),
        ],
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  '${route.distanceKm.toStringAsFixed(1)} км · ${route.durationSeconds ~/ 60} мин',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (route.points.length >= 2)
                  FilledButton.icon(
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('Сохранить маршрут'),
                    onPressed: () async {
                      try {
                        await SavedRoutesRepository().addRoute(
                          route.toSavedRoute(),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Маршрут сохранён — откройте его из меню карты',
                              ),
                            ),
                          );
                        }
                      } catch (_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Не удалось сохранить маршрут'),
                            ),
                          );
                        }
                      }
                    },
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
