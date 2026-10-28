import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

import '../models/ride_media.dart';
import '../models/chat_media_draft.dart';
import '../models/workout_details.dart';
import '../data/ride_media_repository.dart';
import '../data/navigation_preferences.dart';
import '../services/offline_maps_service.dart';
import '../utils/ride_id.dart';
import '../utils/chat_media_files.dart';
import '../widgets/chat_media_composer.dart';
import '../widgets/chat_photo.dart';
import '../widgets/chat_video_player.dart';
import '../widgets/track_media_thumbnail.dart';
import '../models/track_media_groups.dart';

class RideMediaScreen extends StatefulWidget {
  const RideMediaScreen({
    super.key,
    required this.rideId,
    required this.points,
    this.segmentStarts = const [0],
    this.live = false,
    this.initialIndex = 0,
    this.initialMediaId,
  });
  final String rideId;
  final List<LatLng> points;
  final List<int> segmentStarts;
  final bool live;
  final int initialIndex;
  final String? initialMediaId;
  @override
  State<RideMediaScreen> createState() => _RideMediaScreenState();
}

class _RideMediaScreenState extends State<RideMediaScreen> {
  late final _repo = RideMediaRepository(widget.rideId);
  final _picker = ImagePicker();
  final _map = MapController();
  List<RideMedia> _items = [];
  late int _point = widget.points.isEmpty
      ? 0
      : widget.initialIndex.clamp(0, widget.points.length - 1);
  bool _loading = true, _busy = false;
  String? _error;
  String? _selectedId;
  double _zoom = 15;
  bool _mapReady = false;
  void _select(RideMedia item) {
    if (item.pointIndex < 0 || item.pointIndex >= widget.points.length) {
      setState(() => _selectedId = item.id);
      _message(
        'У материала нет точки в текущем треке. Выберите место на карте и нажмите «Место и подпись».',
      );
      return;
    }
    setState(() {
      _selectedId = item.id;
      _point = item.pointIndex.clamp(0, widget.points.length - 1);
    });
    if (_mapReady) _map.move(widget.points[_point], _map.camera.zoom);
  }

  void _group(List<RideMedia> items) {
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
              local: items,
              onSelect: (id) {
                Navigator.pop(sheet);
                _select(items.firstWhere((m) => m.id == id));
              },
              onOpen: (id) {
                Navigator.pop(sheet);
                final item = items.firstWhere((m) => m.id == id);
                _select(item);
                _preview(item);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<void> _load() async {
    try {
      final items = await _repo.load();
      if (mounted) {
        setState(() {
          _items = items;
          final selected = items
              .where((m) => m.id == widget.initialMediaId)
              .firstOrNull;
          if (_selectedId == null &&
              selected != null &&
              widget.points.isNotEmpty) {
            _selectedId = selected.id;
            if (selected.pointIndex < widget.points.length) {
              _point = selected.pointIndex;
            }
          }
          _loading = false;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Не удалось прочитать материалы. Исходные данные сохранены.';
        });
      }
    }
  }

  Future<List<ChatMediaDraft>> _pick(bool video, {bool camera = false}) async {
    final files = video
        ? [await _picker.pickVideo(source: ImageSource.gallery)]
              .whereType<XFile>()
              .toList()
        : camera
        ? [
            await _picker.pickImage(
              source: ImageSource.camera,
              imageQuality: 85,
              maxWidth: 2048,
              maxHeight: 2048,
              requestFullMetadata: false,
            ),
          ].whereType<XFile>().toList()
        : await _picker.pickMultiImage(
            imageQuality: 85,
            maxWidth: 2048,
            maxHeight: 2048,
            requestFullMetadata: false,
            limit: 20,
          );
    return [
      for (final file in files)
        ChatMediaDraft(file: file, isVideo: video, size: await file.length()),
    ];
  }

  Future<String?> _caption({
    String text = '',
    String title = 'Подпись к месту',
  }) async {
    final controller = TextEditingController(text: text);
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Точка ${_point + 1} на треке. Место выбрано вами, а не взято из метаданных файла.',
                ),
                TextField(
                  controller: controller,
                  maxLength: 280,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Подпись (необязательно)',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                if (controller.text.trim().length <= 280) {
                  Navigator.pop(ctx, controller.text.trim());
                }
              },
              child: const Text('Сохранить у этой точки'),
            ),
          ],
        ),
      );
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
  }

  Future<void> _add(bool video, {bool camera = false}) async {
    if (_busy || widget.points.isEmpty || _error != null) return;
    final index = _point; // Capture before the picker; live GPS must not shift the anchor.
    setState(() => _busy = true);
    try {
      final initial = await _pick(video, camera: camera);
      if (!mounted || !_repo.isCurrent || initial.isEmpty) return;
      final error = ChatMediaDraft.validateBatch(initial);
      if (error != null) {
        _message(error);
        return;
      }
      final selected = await Navigator.push<List<ChatMediaDraft>>(
        context,
        MaterialPageRoute(
          builder: (_) => ChatMediaComposer(
            items: initial,
            onAddPhotos: () => _pick(false),
            onAddVideo: () => _pick(true),
          ),
        ),
      );
      if (!mounted || !_repo.isCurrent || selected == null) return;
      if (_items.length + selected.length > 20) {
        _message('В поездке можно сохранить до 20 материалов');
        return;
      }
      final text = await _caption(title: 'Привязать к точке ${index + 1}?');
      if (!mounted || !_repo.isCurrent || text == null) return;
      final items = <RideMedia>[];
      for (final item in selected) {
        final id = newRideId();
        final path = await retainChatMedia(
          item.file,
          _repo.owner ?? 'guest',
          id,
          item.extension,
          editedBytes: item.editedBytes,
        );
        if (!mounted || !_repo.isCurrent) return;
        items.add(
          RideMedia(
            id: id,
            pointIndex: index,
            kind: item.isVideo ? RideMediaKind.video : RideMediaKind.photo,
            localPath: path,
            createdAt: DateTime.now(),
            caption: text,
          ),
        );
      }
      await _repo.add(items, pointCount: widget.points.length);
      await _load();
      if (mounted) {
        _message('Сохранено лично. Публикация выполняется отдельно.');
      }
    } catch (_) {
      if (mounted) {
        _message(
          'Не удалось сохранить материал. Проверьте доступ к файлу и место на устройстве.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _preview(RideMedia item) {
    if (item.kind == RideMediaKind.video) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              ChatVideoPlayer(source: item.localPath, autoPlay: true),
        ),
      );
    } else {
      showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.sizeOf(ctx).height * .8,
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close),
                  ),
                ),
                Expanded(
                  child: InteractiveViewer(
                    child: ChatPhoto(
                      source: item.localPath,
                      onRetry: () async {},
                      fullScreen: true,
                    ),
                  ),
                ),
                Text(item.caption),
              ],
            ),
          ),
        ),
      );
    }
  }

  Future<void> _edit(RideMedia item) async {
    if (_busy) return;
    final index = _point;
    final text = await _caption(
      text: item.caption,
      title: 'Место и подпись материала',
    );
    if (!mounted || text == null) return;
    setState(() => _busy = true);
    try {
      await _repo.update(
        item.at(index, text),
        pointCount: widget.points.length,
      );
      await _load();
    } catch (_) {
      if (mounted) _message('Не удалось изменить материал');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(RideMedia item) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Убрать из личной поездки?'),
        content: const Text(
          'Файл в галерее и ранее отправленные публикации не изменятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Убрать'),
          ),
        ],
      ),
    );
    if (!mounted || yes != true) return;
    setState(() => _busy = true);
    try {
      await _repo.remove(item.id);
      await _load();
    } catch (_) {
      if (mounted) _message('Не удалось убрать материал');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = widget.points;
    return Scaffold(
      appBar: AppBar(title: const Text('Фото и видео на треке')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  if (points.isNotEmpty)
                    Expanded(
                      flex: 3,
                      child: FlutterMap(
                        mapController: _map,
                        options: MapOptions(
                          initialCenter: points[_point],
                          initialZoom: 15,
                          onMapReady: () => _mapReady = true,
                          onPositionChanged: (camera, _) {
                            if ((camera.zoom - _zoom).abs() > .25 && mounted) {
                              setState(() => _zoom = camera.zoom);
                            }
                          },
                          initialCameraFit: points.length < 2
                              ? null
                              : CameraFit.bounds(
                                  bounds: LatLngBounds.fromPoints(points),
                                  padding: const EdgeInsets.all(48),
                                  maxZoom: 16,
                                ),
                          onTap: (_, point) {
                            if (_busy) return;
                            const measure = Distance();
                            var best = double.infinity, index = 0;
                            for (var i = 0; i < points.length; i++) {
                              final distance = measure(point, points[i]);
                              if (distance < best) {
                                best = distance;
                                index = i;
                              }
                            }
                            setState(() => _point = index);
                          },
                        ),
                        children: [
                          if (!NavigationPreferences.instance.cachedMapOnly ||
                              OfflineMapsService.isAvailable)
                            TileLayer(
                              urlTemplate: OfflineMapsService.routeTileUrl,
                              tileProvider: OfflineMapsService.tileProvider(
                                offlineOnly: NavigationPreferences
                                    .instance
                                    .cachedMapOnly,
                              ),
                              userAgentPackageName: 'com.pulsepath.app',
                            ),
                          PolylineLayer(
                            polylines: [
                              for (final segment in WorkoutDetails.splitTrack(
                                points,
                                widget.segmentStarts,
                              ))
                                Polyline(
                                  points: segment,
                                  color: Colors.deepOrange,
                                  strokeWidth: 4,
                                ),
                            ],
                          ),
                          MarkerLayer(
                            markers: [
                              for (final group in groupTrackMedia(
                                _items,
                                points,
                                (item) => item.pointIndex,
                                _zoom,
                              ))
                                Marker(
                                  point: points[group.first.pointIndex],
                                  width: 32,
                                  height: 32,
                                  child: TrackMediaThumbnail(
                                    local: group.first,
                                    count: group.length,
                                    selected: group.any(
                                      (m) => m.id == _selectedId,
                                    ),
                                    onTap: () => _group(group),
                                  ),
                                ),
                              if (!_items.any((m) => m.pointIndex == _point))
                                Marker(
                                  point: points[_point],
                                  width: 40,
                                  height: 40,
                                  child: const Icon(
                                    Icons.location_on,
                                    color: Colors.blue,
                                    size: 40,
                                  ),
                                ),
                            ],
                          ),
                          const RichAttributionWidget(
                            attributions: [
                              TextSourceAttribution(
                                '© OpenStreetMap contributors',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  if (_items.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${_items.length} материалов · миниатюра показывает место на карте',
                    ),
                    TrackMediaStrip(
                      local: _items,
                      selectedId: _selectedId,
                      onSelect: (id) =>
                          _select(_items.firstWhere((m) => m.id == id)),
                      onOpen: (id) {
                        final item = _items.firstWhere((m) => m.id == id);
                        _select(item);
                        _preview(item);
                      },
                    ),
                    if (_selectedId != null &&
                        _items.any((m) => m.id == _selectedId))
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _edit(
                                    _items.firstWhere(
                                      (m) => m.id == _selectedId,
                                    ),
                                  ),
                            icon: const Icon(Icons.edit_location_alt_outlined),
                            label: const Text('Место и подпись'),
                          ),
                          TextButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _remove(
                                    _items.firstWhere(
                                      (m) => m.id == _selectedId,
                                    ),
                                  ),
                            icon: const Icon(Icons.remove_circle_outline),
                            label: const Text('Убрать'),
                          ),
                        ],
                      ),
                  ],

                  Expanded(
                    flex: 2,
                    child: ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        if (_error != null)
                          ListTile(
                            title: Text(_error!),
                            trailing: IconButton(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh),
                            ),
                          ),
                        if (points.isEmpty)
                          const Text(
                            'Нужна хотя бы одна записанная GPS-точка. Место не будет подставлено автоматически.',
                          ),
                        if (widget.live)
                          const Text(
                            'Запись продолжается. Выберите место на уже записанном участке. Поделиться материалами можно после сохранения поездки.',
                          ),
                        const Text(
                          'Лично на этом устройстве. Для публикации выберите материалы отдельно в окне отправки поездки.',
                        ),
                        if (points.isNotEmpty) ...[
                          Text(
                            'Выбрана точка ${_point + 1} / ${points.length}',
                          ),
                          Slider(
                            value: _point.toDouble(),
                            max: (points.length - 1)
                                .clamp(1, 1000000)
                                .toDouble(),
                            onChanged: _busy
                                ? null
                                : (value) => setState(
                                    () => _point = value.round().clamp(
                                      0,
                                      points.length - 1,
                                    ),
                                  ),
                          ),
                        ],
                        Wrap(
                          spacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed:
                                  _busy || points.isEmpty || _error != null
                                  ? null
                                  : () => _add(false),
                              icon: const Icon(Icons.add_photo_alternate),
                              label: const Text('Фото'),
                            ),
                            OutlinedButton.icon(
                              onPressed:
                                  _busy || points.isEmpty || _error != null
                                  ? null
                                  : () => _add(false, camera: true),
                              icon: const Icon(Icons.camera_alt),
                              label: const Text('Камера'),
                            ),
                            OutlinedButton.icon(
                              onPressed:
                                  _busy || points.isEmpty || _error != null
                                  ? null
                                  : () => _add(true),
                              icon: const Icon(Icons.video_library),
                              label: const Text('Видео'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
