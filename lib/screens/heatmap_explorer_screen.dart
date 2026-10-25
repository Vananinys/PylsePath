import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/user_scope.dart';
import '../data/workout_history_repository.dart';
import '../models/saved_route.dart';
import '../models/workout_record.dart';
import '../services/heatmap_explorer.dart';
import '../services/offline_maps_service.dart';
import '../services/training_heatmap.dart';
import '../widgets/heatmap_path_layer.dart';
import '../widgets/map_credits.dart';
import 'workout_detail_screen.dart';

class RideHeatmapScreen extends StatefulWidget {
  const RideHeatmapScreen({super.key, this.previewRides, this.tileProvider});

  /// Developer preview uses an isolated in-memory collection, never history.
  final List<SavedRoute>? previewRides;
  final TileProvider? tileProvider;
  @override
  State<RideHeatmapScreen> createState() => _HeatmapExplorerState();
}

class _HeatmapExplorerState extends State<RideHeatmapScreen> {
  final _map = MapController();
  final _repo = WorkoutHistoryRepository();
  List<SavedRoute> _rides = [];
  bool _loading = true, _busy = false, _ready = false;
  bool _personal = true, _public = false, _dark = true;
  bool _consent = false, _consentLoaded = false;
  int _palette = 0, _revision = 0;
  double _opacity = .85, _width = 5;
  HeatmapFilter _filter = const HeatmapFilter();
  String _status = 'Загрузка истории…';
  List<SavedRoute> get _selected => _rides
      .where(_filter.matches)
      .where((r) => r.routePoints.where(HeatmapGeometry.valid).length >= 2)
      .toList();
  String get _prefsKey =>
      UserScope.keyFor('heatmap_explorer_v1', UserScope.currentUserId());
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final owner = UserScope.currentUserId();
    try {
      if (widget.previewRides != null) {
        _rides = widget.previewRides!;
      } else {
        await _repo.load();
        _rides = _repo.workoutHistory;
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_prefsKey);
        if (raw != null) {
          try {
            final data = jsonDecode(raw) as Map;
            _dark = data['dark'] != false;
            _personal = data['personal'] != false;
            _public = data['public'] == true;
            _palette = (data['palette'] as num? ?? 0).toInt().clamp(0, 2);
            _opacity = (data['opacity'] as num? ?? .85).toDouble().clamp(
              .15,
              1,
            );
            _width = (data['width'] as num? ?? 5).toDouble().clamp(2, 10);
            _filter = HeatmapFilter(
              sport: HeatSport.values.firstWhere(
                (s) => s.name == data['sport'],
                orElse: () => HeatSport.all,
              ),
              start: DateTime.tryParse(data['start']?.toString() ?? ''),
              end: DateTime.tryParse(data['end']?.toString() ?? ''),
            );
          } catch (_) {
            /* Original preferences remain available on disk. */
          }
        }
      }
    } catch (_) {
      _status = 'Не удалось прочитать историю. Нажмите обновление.';
    }
    if (!mounted || owner != UserScope.currentUserId()) return;
    setState(() {
      _loading = false;
      _status = _rides.isEmpty
          ? 'Пока нет записанных GPS-треков'
          : 'Готовим тепловую карту…';
    });
    if (widget.previewRides == null) unawaited(_refreshCloud());
  }

  Future<void> _save() async {
    if (widget.previewRides != null) return;
    final owner = UserScope.currentUserId(), key = _prefsKey;
    final value = jsonEncode({
      'dark': _dark,
      'personal': _personal,
      'public': _public,
      'palette': _palette,
      'opacity': _opacity,
      'width': _width,
      'sport': _filter.sport.name,
      'start': _filter.start?.toIso8601String(),
      'end': _filter.end?.toIso8601String(),
    });
    final prefs = await SharedPreferences.getInstance();
    if (owner == UserScope.currentUserId()) await prefs.setString(key, value);
  }

  Future<void> _refreshCloud() async {
    if (_busy || widget.previewRides != null) return;
    setState(() => _busy = true);
    final owner = UserScope.currentUserId();
    try {
      await _repo.restoreFromCloud();
      if (!mounted || owner != UserScope.currentUserId()) return;
      setState(() {
        _rides = _repo.workoutHistory;
        _revision++;
      });
    } catch (_) {
      if (mounted)
        setState(
          () => _status = 'Нет связи с облаком · показана сохранённая история',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fit() {
    if (!_ready) return;
    final points = _selected
        .expand((r) => r.routePoints)
        .where(HeatmapGeometry.valid)
        .toList();
    if (points.isEmpty) {
      setState(() => _status = 'Нет GPS-треков по выбранным фильтрам');
      return;
    }
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.all(45),
        maxZoom: 16,
      ),
    );
  }

  Future<void> _locate() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied)
        permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever)
        throw StateError('permission');
      final fix = await Geolocator.getCurrentPosition(
        timeLimit: const Duration(seconds: 20),
      );
      if (mounted && _ready) _map.move(LatLng(fix.latitude, fix.longitude), 14);
    } catch (_) {
      if (mounted)
        setState(
          () => _status =
              'Не удалось получить GPS. Проверьте разрешение и геолокацию.',
        );
    }
  }

  Future<void> _inspect(LatLng point) async {
    if (!_personal) return;
    final tolerance = (156543.03 / (1 << _map.camera.zoom.floor()) * 24).clamp(
      30.0,
      600.0,
    );
    final nearby =
        _selected
            .where(
              (r) => HeatmapGeometry.distanceToTrack(point, r) <= tolerance,
            )
            .toList()
          ..sort((a, b) => b.dateTime.compareTo(a.dateTime));
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(c).height * .55,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'На этом участке: ${nearby.length}',
                style: Theme.of(c).textTheme.titleLarge,
              ),
              if (nearby.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Коснитесь линии вашей тренировки. Публичные треки отдельных людей недоступны.',
                  ),
                ),
              for (final r in nearby)
                ListTile(
                  leading: Icon(r.activityType.icon),
                  title: Text(r.title),
                  subtitle: Text(
                    '${r.distanceKm.toStringAsFixed(1)} км · ${r.durationMin.round()} мин · ${r.dateTime.toLocal().toString().substring(0, 10)}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.pop(c);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => WorkoutDetailScreen(
                          workout: WorkoutRecord.fromSavedRoute(r),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _changeConsent(
    bool value,
    void Function(void Function()) update,
  ) async {
    if (value) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Участвовать в публичной карте?'),
          content: const SingleChildScrollView(
            child: Text(
              'Обрабатываются облачные GPS-треки, включая историю. Публикуются только ячейки примерно 300–550 м с минимум 3 участниками. Радиус 1 км вокруг начала и конца каждого участка скрыт. Задержка — минимум сутки. Имена, точные треки и время не публикуются. Выключение удаляет ваш вклад.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Участвовать'),
            ),
          ],
        ),
      );
      if (yes != true) return;
    }
    update(() => _busy = true);
    try {
      await TrainingHeatmap.setConsent(value);
      if (mounted)
        update(() {
          _consent = value;
          _revision++;
        });
    } catch (_) {
      if (mounted)
        update(
          () => _status =
              'Не удалось сохранить участие. Повторите при наличии сети.',
        );
    } finally {
      if (mounted) update(() => _busy = false);
    }
  }

  Future<void> _settings() async {
    if (widget.previewRides == null) {
      try {
        _consent = await TrainingHeatmap.consent().timeout(
          const Duration(seconds: 8),
        );
        _consentLoaded = true;
      } catch (_) {
        _consentLoaded = false;
      }
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (c, update) {
          void change(VoidCallback action) {
            setState(action);
            update(() {});
            unawaited(_save());
          }

          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(c).height * .83,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                children: [
                  Text(
                    'Настроить тепловую карту',
                    style: Theme.of(c).textTheme.titleLarge,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Мои тренировки'),
                    value: _personal,
                    onChanged: (v) => change(() => _personal = v),
                  ),
                  if (widget.previewRides == null)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Публичная карта'),
                      subtitle: const Text('Можно совместить с личной'),
                      value: _public,
                      onChanged: (v) => change(() => _public = v),
                    ),
                  const Text('Вид активности'),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final s in HeatSport.values)
                        ChoiceChip(
                          label: Text(s.label),
                          selected: _filter.sport == s,
                          onSelected: (_) => change(
                            () => _filter = HeatmapFilter(
                              sport: s,
                              start: _filter.start,
                              end: _filter.end,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Text('Период'),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final days in [0, 7, 30, 90, 365])
                        ActionChip(
                          label: Text(days == 0 ? 'Всё время' : '$days дней'),
                          onPressed: () => change(() {
                            final now = DateTime.now();
                            _filter = HeatmapFilter(
                              sport: _filter.sport,
                              start: days == 0
                                  ? null
                                  : DateTime(
                                      now.year,
                                      now.month,
                                      now.day - days + 1,
                                    ),
                              end: days == 0 ? null : now,
                            );
                          }),
                        ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final year
                          in (_rides
                              .map((r) => r.recordedDateTime?.year)
                              .whereType<int>()
                              .toSet()
                              .toList()
                            ..sort((a, b) => b.compareTo(a))))
                        ActionChip(
                          label: Text('$year'),
                          onPressed: () => change(
                            () => _filter = HeatmapFilter(
                              sport: _filter.sport,
                              start: DateTime(year),
                              end: DateTime(year, 12, 31),
                            ),
                          ),
                        ),
                    ],
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.date_range),
                    title: const Text('Произвольные даты'),
                    subtitle: Text(_periodLabel),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final now = DateTime.now();
                      final range = await showDateRangePicker(
                        context: c,
                        firstDate: DateTime(2000),
                        lastDate: now,
                        initialDateRange:
                            _filter.start != null &&
                                _filter.end != null &&
                                !_filter.end!.isAfter(now)
                            ? DateTimeRange(
                                start: _filter.start!,
                                end: _filter.end!,
                              )
                            : null,
                      );
                      if (range != null && mounted && c.mounted)
                        change(
                          () => _filter = HeatmapFilter(
                            sport: _filter.sport,
                            start: range.start,
                            end: range.end,
                          ),
                        );
                    },
                  ),
                  const Text('Цвет тепла'),
                  Wrap(
                    spacing: 10,
                    children: [
                      for (var i = 0; i < heatPalettes.length; i++)
                        ChoiceChip(
                          avatar: CircleAvatar(
                            backgroundColor: heatPalettes[i][1],
                            radius: 9,
                          ),
                          label: Text(['Контраст', 'Лёд', 'Огонь'][i]),
                          selected: _palette == i,
                          onSelected: (_) => change(() => _palette = i),
                        ),
                    ],
                  ),
                  Text('Непрозрачность: ${(_opacity * 100).round()}%'),
                  Slider(
                    value: _opacity,
                    min: .15,
                    max: 1,
                    onChanged: (v) => change(() => _opacity = v),
                  ),
                  const Text('Ширина линий'),
                  Slider(
                    value: _width,
                    min: 2,
                    max: 10,
                    onChanged: (v) => change(() => _width = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Тёмная подложка'),
                    value: _dark,
                    onChanged: (v) => change(() => _dark = v),
                  ),
                  if (widget.previewRides == null)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Мой вклад в публичную карту'),
                      subtitle: Text(
                        _consentLoaded
                            ? 'Добровольно · выключение удаляет вклад'
                            : 'Не удалось загрузить согласие. Повторите открытие настроек.',
                      ),
                      value: _consent,
                      onChanged: _busy || !_consentLoaded
                          ? null
                          : (v) => _changeConsent(v, (fn) {
                              if (c.mounted) {
                                update(fn);
                                setState(() {});
                              }
                            }),
                    ),
                  TextButton(
                    onPressed: () => change(() {
                      _personal = true;
                      _public = false;
                      _filter = const HeatmapFilter();
                      _palette = 0;
                      _opacity = .85;
                      _width = 5;
                      _dark = true;
                    }),
                    child: const Text('Сбросить настройки карты'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text('Готово'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String get _periodLabel => _filter.start == null
      ? 'Всё время'
      : '${_filter.start!.toString().substring(0, 10)} — ${_filter.end?.toString().substring(0, 10) ?? 'сегодня'}';
  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.previewRides == null
            ? 'Тепловая карта'
            : 'Тестовая тепловая карта',
      ),
      actions: [
        IconButton(
          tooltip: 'Обновить историю',
          onPressed: _busy
              ? null
              : () {
                  if (widget.previewRides != null) {
                    setState(() => _revision++);
                  } else {
                    _refreshCloud();
                  }
                },
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Фильтры и оформление',
          onPressed: _settings,
          icon: const Icon(Icons.tune),
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${_filter.sport.label} · $_periodLabel\n${_selected.length} тренировок · ${_selected.fold(0.0, (s, r) => s + r.distanceKm).toStringAsFixed(1)} км',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _map,
                      options: MapOptions(
                        backgroundColor: _dark
                            ? const Color(0xFF151821)
                            : const Color(0xFFF1F1ED),
                        initialCenter: const LatLng(52.54, 85.2),
                        initialZoom: 12,
                        onMapReady: () {
                          _ready = true;
                          _fit();
                        },
                        onTap: (_, point) => _inspect(point),
                      ),
                      children: [
                        ColorFiltered(
                          // Darken the key-free OSM tiles locally. Only the
                          // basemap is filtered; heat colours stay unchanged.
                          colorFilter: ColorFilter.matrix(_dark
                              ? const [
                                  -.30, -.30, -.30, 0, 235,
                                  -.30, -.30, -.30, 0, 238,
                                  -.30, -.30, -.30, 0, 245,
                                  0, 0, 0, 1, 0,
                                ]
                              : const [
                                  1, 0, 0, 0, 0,
                                  0, 1, 0, 0, 0,
                                  0, 0, 1, 0, 0,
                                  0, 0, 0, 1, 0,
                                ]),
                          child: TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            tileProvider:
                                widget.tileProvider ??
                                OfflineMapsService.tileProvider(),
                            userAgentPackageName: 'com.pulsepath.app',
                            maxNativeZoom: 19,
                          ),
                        ),
                        HeatmapPathLayer(
                          personal: _personal,
                          public: _public && widget.previewRides == null,
                          filter: _filter,
                          rides: _rides,
                          palette: _palette,
                          opacity: _opacity,
                          width: _width,
                          revision: _revision,
                          onStatus: (s) {
                            if (mounted && s != _status)
                              setState(() => _status = s);
                          },
                        ),
                        Align(
                          alignment: Alignment.bottomRight,
                          child: MapCredits(),
                        ),
                      ],
                    ),
                    Positioned(
                      right: 12,
                      top: 12,
                      child: Column(
                        children: [
                          FloatingActionButton.small(
                            heroTag: 'heat-fit',
                            tooltip: 'Показать все выбранные треки',
                            onPressed: _fit,
                            child: const Icon(Icons.fit_screen),
                          ),
                          const SizedBox(height: 8),
                          FloatingActionButton.small(
                            heroTag: 'heat-location',
                            tooltip: 'Моё местоположение',
                            onPressed: _locate,
                            child: const Icon(Icons.my_location),
                          ),
                        ],
                      ),
                    ),
                    if (!_personal && !_public)
                      const Center(
                        child: Card(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('Включите слой в настройках карты'),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            gradient: LinearGradient(
                              colors: heatPalettes[_palette],
                            ),
                          ),
                        ),
                      ),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Реже', style: TextStyle(fontSize: 11)),
                          Text('Чаще', style: TextStyle(fontSize: 11)),
                        ],
                      ),
                      Text(_status, style: const TextStyle(fontSize: 12)),
                      const Text(
                        'Нажмите на линию, чтобы открыть тренировки участка',
                        style: TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
  );
}
