import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart' hide ActivityType;

import '../config/app_variant.dart';
import '../data/navigation_preferences.dart';
import '../data/saved_routes_repository.dart';
import '../data/user_scope.dart';
import '../models/activity_type.dart';
import '../models/route_edit_state.dart';
import '../models/saved_route.dart';
import '../services/geocoding_service.dart';
import '../services/offline_maps_service.dart';
import '../services/routing_service.dart';
import '../widgets/primary_map_portal.dart';
import 'route_geometry_editor_screen.dart';

/// Plans with user waypoints; road geometry is never used as editable stops.
class RouteBuilderScreen extends StatefulWidget {
  const RouteBuilderScreen({
    super.key,
    this.source,
    this.initialCenter,
    this.routingService,
  });
  final SavedRoute? source;
  final LatLng? initialCenter;
  final RoutingService? routingService;
  @override
  State<RouteBuilderScreen> createState() => _RouteBuilderScreenState();
}

class _RouteBuilderScreenState extends State<RouteBuilderScreen> {
  final _localMap = MapController();
  final _owner = UserScope.currentUserId();
  final _stops = <LatLng>[];
  final _labels = <String>[];
  final _undo = <({List<LatLng> points, List<String> labels})>[];
  final _redo = <({List<LatLng> points, List<String> labels})>[];
  RoutingResult? _route;
  bool _roads = true, _busy = false, _changed = false;
  Map<String, dynamic>? _recovery;
  Future<void> _writes = Future.value();
  bool get _useGeometryEditor =>
      widget.source != null &&
      (widget.source!.workoutDetails.segmentStarts.length > 1 ||
          (widget.source!.planningPoints.isEmpty &&
              widget.source!.viaPoints.isEmpty &&
              widget.source!.routePoints.length > 10) ||
          widget.source!.routePoints.length < 2);
  String get _draftKey => UserScope.keyFor(
    'route_planner_draft_v1${widget.source == null ? "" : "_${widget.source!.localId}"}',
    _owner,
  );
  @override
  void initState() {
    super.initState();
    final source = widget.source;
    if (source == null) {
      _busy = true;
      _loadDraft();
    } else if (!_useGeometryEditor) {
      _stops.addAll(
        source.planningPoints.isNotEmpty
            ? source.planningPoints
            : source.viaPoints.isNotEmpty
            ? [
                source.routePoints.first,
                ...source.viaPoints,
                source.routePoints.last,
              ]
            : source.routePoints,
      );
      _labels.addAll(
        source.planningLabels.length == _stops.length
            ? source.planningLabels
            : _stops.map(
                (p) =>
                    '${p.latitude.toStringAsFixed(4)}, ${p.longitude.toStringAsFixed(4)}',
              ),
      );
      _activity = source.activityType;
      _roads = (source.durationSeconds ?? 0) > 0;
      if (_roads) {
        _route = RoutingResult(
          points: source.routePoints,
          steps: source.navigationSteps,
          distanceKm: (source.distanceMeters ?? 0) / 1000,
          durationMin: source.durationSeconds! / 60,
        );
      }
      _busy = true;
      _loadDraft();
    }
  }

  Future<void> _loadDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_draftKey);
      if (raw == null || raw.isEmpty || !mounted || !_owned || _changed) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final points = (data["points"] as List)
          .map(
            (p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
          )
          .toList();
      if (points.isEmpty ||
          points.length > 10 ||
          points.any((p) => !RoutingService.validPoint(p))) {
        return;
      }
      if ((data["labels"] as List).length != points.length) return;
      if (!ActivityType.values.any((a) => a.name == data["activity"])) return;
      _recovery = data;
      _refresh();
    } catch (_) {
      /* Keep unreadable drafts intact. */
    } finally {
      _busy = false;
      _refresh();
    }
  }

  Future<void> _persist({bool clear = false}) {
    final raw = clear
        ? ""
        : jsonEncode({
            "points": [
              for (final p in _stops) [p.latitude, p.longitude],
            ],
            "labels": _labels,
            "roads": _roads,
            "activity": _activity.name,
          });
    final next = _writes.then((_) async {
      if (!_owned) return;
      final prefs = await SharedPreferences.getInstance();
      if (!_owned) return;
      if (!await prefs.setString(_draftKey, raw)) {
        throw StateError("draft write failed");
      }
    });
    _writes = next.catchError((Object _) {
      _message(
        "Черновик не удалось сохранить. Сохраните маршрут перед выходом.",
      );
    });
    return _writes;
  }

  Future<void> _resume() async {
    final d = _recovery;
    if (d == null || !_owned) return;
    _stops.clear();
    _labels.clear();
    _stops.addAll(
      (d["points"] as List).map(
        (p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
      ),
    );
    _labels.addAll((d["labels"] as List).cast<String>());
    _roads = d["roads"] == true;
    _activity = ActivityType.values.firstWhere((a) => a.name == d["activity"]);
    _recovery = null;
    _changed = true;
    await _persist();
    await _calculate();
  }

  String? _error;
  int? _replace;
  ActivityType _activity = ActivityType.cycling;
  MapController get _map => PrimaryMapNavigation.instance.resolve(_localMap);
  bool get _owned => UserScope.currentUserId() == _owner;
  bool get _canSave =>
      _owned &&
      !_busy &&
      _recovery == null &&
      _stops.length >= 2 &&
      (!_roads || _route != null);
  @override
  void dispose() {
    _localMap.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
      PrimaryMapNavigation.instance.refresh();
    }
  }

  ({List<LatLng> points, List<String> labels}) _snapshot() =>
      (points: List.of(_stops), labels: List.of(_labels));
  Future<void> _change(VoidCallback edit) async {
    if (_busy || !_owned || _recovery != null) return;
    _undo.add(_snapshot());
    if (_undo.length > 30) _undo.removeAt(0);
    _redo.clear();
    _busy = true;
    edit();
    _changed = true;
    _replace = null;
    await _persist();
    await _calculate();
  }

  Future<void> _calculate() async {
    if (!_owned || !mounted) return;
    _route = null;
    _error = null;
    _busy = false;
    if (!_roads || _stops.length < 2) {
      _refresh();
      return;
    }
    _busy = true;
    _refresh();
    try {
      final result = await (widget.routingService ?? RoutingService())
          .buildRoute(
            start: _stops.first,
            end: _stops.last,
            via: _stops.sublist(1, _stops.length - 1),
            activity: _activity,
          );
      if (!mounted || !_owned) return;
      _route = result;
    } catch (e) {
      _error = e is RoutingException
          ? e.message
          : 'Не удалось построить путь. Проверьте интернет и повторите.';
    } finally {
      _busy = false;
      _refresh();
    }
  }

  Future<void> _point(
    LatLng point, [
    String? name,
    bool appendEnd = false,
  ]) async {
    if (_busy) return;
    if (_replace == null && _stops.length >= 10) {
      _message('Можно добавить до 8 остановок между стартом и финишем.');
      return;
    }
    await _change(() {
      final label =
          name ??
          '${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}';
      if (_replace case final int index) {
        _stops[index] = point;
        _labels[index] = label;
      } else {
        final index = !appendEnd && _stops.length >= 2
            ? _stops.length - 1
            : _stops.length;
        _stops.insert(index, point);
        _labels.insert(index, label);
      }
    });
  }

  Future<void> _history(bool redo) async {
    if (_busy || !_owned) return;
    final from = redo ? _redo : _undo, to = redo ? _undo : _redo;
    if (from.isEmpty) return;
    _busy = true;
    to.add(_snapshot());
    final next = from.removeLast();
    _stops
      ..clear()
      ..addAll(next.points);
    _labels
      ..clear()
      ..addAll(next.labels);
    _replace = null;
    _changed = true;
    await _persist();
    await _calculate();
  }

  Future<void> _locate() async {
    if (_busy) return;
    _busy = true;
    _refresh();
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _message('Разрешите геопозицию или выберите точку на карте.');
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        timeLimit: const Duration(seconds: 15),
      );
      if (!mounted || !_owned) return;
      _busy = false;
      await _point(
        LatLng(position.latitude, position.longitude),
        'Моё местоположение',
      );
    } catch (_) {
      _message(
        'Не удалось определить местоположение. Выберите точку на карте.',
      );
    } finally {
      _busy = false;
      _refresh();
    }
  }

  Future<void> _search() async {
    final result = await showSearch<Map<String, dynamic>?>(
      context: context,
      delegate: _PlaceSearch(),
    );
    if (!mounted || !_owned || result == null) return;
    final point = LatLng(
      double.parse('${result['lat']}'),
      double.parse('${result['lon']}'),
    );
    await _point(point, '${result['display_name']}');
    if (mounted && _owned) {
      try {
        _map.move(point, 14);
      } catch (_) {}
    }
  }

  RouteEditState get _geometry => RouteEditState(
    _route?.points ?? _stops,
    controls: _stops,
    estimatedSeconds: _route == null
        ? null
        : (_route!.durationMin * 60).round(),
    steps: _route?.steps ?? const [],
  );
  Future<void> _save() async {
    if (!_canSave || !_owned) return;
    var name = widget.source == null
        ? 'Мой маршрут'
        : '${widget.source!.title} — копия';
    var notes = widget.source?.routeNotes ?? '';
    final form = GlobalKey<FormState>();
    final details = await showModalBottomSheet<({String title, String notes})>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          MediaQuery.viewInsetsOf(sheet).bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Сохранить маршрут',
                  style: Theme.of(sheet).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  initialValue: name,
                  onChanged: (v) => name = v,
                  maxLength: 120,
                  decoration: const InputDecoration(labelText: 'Название'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Введите название' : null,
                ),
                TextFormField(
                  initialValue: notes,
                  onChanged: (v) => notes = v,
                  maxLength: 2000,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Заметка · необязательно',
                  ),
                ),
                FilledButton(
                  onPressed: () {
                    if (form.currentState!.validate()) {
                      Navigator.pop(sheet, (title: name.trim(), notes: notes));
                    }
                  },
                  child: const Text('Сохранить'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!mounted || !_owned || details == null) return;
    _busy = true;
    _refresh();
    try {
      await SavedRoutesRepository().addRoute(
        _geometry.plannedCopy(
          title: details.title,
          notes: details.notes,
          activity: _activity,
          waypointLabels: _labels,
          collection: widget.source?.collection ?? '',
        ),
      );
      if (mounted && _owned) {
        _busy = false;
        setState(() => _changed = false);
        await _persist(clear: true);
        if (mounted) {
          final ownRoute = ModalRoute.of(context);
          Navigator.of(context).popUntil((r) => r == ownRoute);
          Navigator.of(context).pop(true);
        }
      }
    } catch (_) {
      _message(
        'Не удалось сохранить маршрут на устройстве. Повторите попытку.',
      );
    } finally {
      _busy = false;
      _refresh();
    }
  }

  Future<void> _leave() async {
    if (_busy) return;
    if (!_changed) {
      Navigator.pop(context);
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из конструктора?'),
        content: const Text(
          'Черновик останется на устройстве. Его можно продолжить при следующем открытии.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Продолжить создание'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Выйти с черновиком'),
          ),
        ],
      ),
    );
    if (mounted && leave == true) {
      setState(() => _changed = false);
      Navigator.pop(context);
    }
  }

  String _role(int i) => i == 0
      ? 'Старт'
      : i == _stops.length - 1
      ? 'Финиш'
      : 'Остановка $i';
  Widget _saveButton(BuildContext context) => FilledButton.icon(
    onPressed: _canSave ? _save : null,
    icon: const Icon(Icons.bookmark_add_outlined),
    label: const Text('Сохранить маршрут'),
  );
  Widget _panel(BuildContext context) {
    if (!_owned) {
      return const Text('Аккаунт изменился. Откройте конструктор заново.');
    }
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_recovery != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Есть незавершённый маршрут'),
                  FilledButton(
                    onPressed: _resume,
                    child: const Text('Продолжить черновик'),
                  ),
                  TextButton(
                    onPressed: () async {
                      await _persist(clear: true);
                      _recovery = null;
                      _refresh();
                    },
                    child: const Text('Начать новый маршрут'),
                  ),
                ],
              ),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: Text(
                _stops.isEmpty
                    ? 'Маршрут'
                    : '${(_geometry.meters / 1000).toStringAsFixed(1)} км',
                style: theme.textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: 'Отменить',
              onPressed: _busy || _undo.isEmpty ? null : () => _history(false),
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: 'Повторить',
              onPressed: _busy || _redo.isEmpty ? null : () => _history(true),
              icon: const Icon(Icons.redo),
            ),
          ],
        ),
        Text(
          _busy
              ? 'Строим путь по дорогам…'
              : _route != null
              ? 'Примерно ${_route!.durationMin.ceil()} мин · по дорогам'
              : _roads
              ? 'Выберите старт и финиш'
              : 'Вручную · проходимость не проверена',
          style: theme.textTheme.bodyMedium,
        ),
        if (_busy) const LinearProgressIndicator(),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _search,
          icon: const Icon(Icons.search),
          label: const Text('Найти адрес или место'),
        ),
        if (_stops.isEmpty)
          TextButton.icon(
            onPressed: _busy ? null : _locate,
            icon: const Icon(Icons.my_location),
            label: const Text('Начать от меня'),
          ),
        if (_replace != null)
          Material(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(16),
            child: ListTile(
              title: Text('Выберите новое место: ${_role(_replace!)}'),
              trailing: IconButton(
                tooltip: 'Отменить перенос',
                onPressed: () {
                  _replace = null;
                  _refresh();
                },
                icon: const Icon(Icons.close),
              ),
            ),
          ),
        if (_stops.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Нажмите на карту, чтобы поставить старт. Следующее нажатие добавит финиш.',
            ),
          ),
        if (_stops.isNotEmpty)
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: _stops.length,
            onReorderItem: (oldIndex, newIndex) {
              if (_busy) return;
              _change(() {
                final point = _stops.removeAt(oldIndex),
                    label = _labels.removeAt(oldIndex);
                _stops.insert(newIndex, point);
                _labels.insert(newIndex, label);
              });
            },
            itemBuilder: (ctx, i) => ListTile(
              key: ValueKey(i),
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(
                  i == 0
                      ? 'A'
                      : i == _stops.length - 1
                      ? 'B'
                      : '$i',
                ),
              ),
              title: Text(_role(i)),
              subtitle: Text(
                _labels[i],
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: _busy
                  ? null
                  : () {
                      _replace = i;
                      _refresh();
                    },
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Убрать ${_role(i).toLowerCase()}',
                    onPressed: _busy
                        ? null
                        : () => _change(() {
                            _stops.removeAt(i);
                            _labels.removeAt(i);
                          }),
                    icon: const Icon(Icons.close),
                  ),
                  ReorderableDragStartListener(
                    index: i,
                    enabled: !_busy,
                    child: const SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_stops.length >= 2)
          Text(
            'Нажмите на карту, чтобы добавить остановку перед финишем. Нажмите на точку для переноса, удерживайте ≡ для изменения порядка.',
            style: theme.textTheme.bodySmall,
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('По дорогам'),
              selected: _roads,
              onSelected: _busy
                  ? null
                  : (_) {
                      _roads = true;
                      _changed = true;
                      _persist();
                      _calculate();
                    },
            ),
            ChoiceChip(
              label: const Text('Вручную'),
              selected: !_roads,
              onSelected: _busy
                  ? null
                  : (_) {
                      _roads = false;
                      _changed = true;
                      _persist();
                      _calculate();
                    },
            ),
            if (_stops.length >= 2)
              ActionChip(
                label: const Text('Обратно'),
                avatar: const Icon(Icons.swap_vert),
                onPressed: _busy
                    ? null
                    : () => _change(() {
                        final p = _stops.reversed.toList(),
                            l = _labels.reversed.toList();
                        _stops
                          ..clear()
                          ..addAll(p);
                        _labels
                          ..clear()
                          ..addAll(l);
                      }),
              ),
            if (_stops.length >= 2 && _stops.length < 10)
              ActionChip(
                label: const Text('Вернуться к старту'),
                avatar: const Icon(Icons.loop),
                onPressed: _busy
                    ? null
                    : () => _point(_stops.first, _labels.first, true),
              ),
          ],
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<ActivityType>(
          initialValue: _activity,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Активность'),
          items: [
            for (final a in ActivityType.values)
              DropdownMenuItem(value: a, child: Text(a.label)),
          ],
          onChanged: _busy
              ? null
              : (a) {
                  if (a != null) {
                    _activity = a;
                    _changed = true;
                    _persist();
                    _calculate();
                  }
                },
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (_error != null)
          TextButton.icon(
            onPressed: _busy ? null : _calculate,
            icon: const Icon(Icons.refresh),
            label: const Text('Повторить построение'),
          ),
        const SizedBox(height: 16),
        if (!PrimaryMapNavigation.instance.active) _saveButton(context),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Preserve precise editing of imported/recorded tracks and all legacy tools.
    if (_useGeometryEditor) {
      return RouteGeometryEditorScreen(
        source: widget.source,
        initialCenter: widget.initialCenter,
        routingService: widget.routingService,
      );
    }
    final colors = Theme.of(context).colorScheme;
    final map = FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: _stops.isEmpty
            ? widget.initialCenter ?? const LatLng(55.75, 37.61)
            : _stops.first,
        initialCameraFit: _stops.length < 2
            ? null
            : CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(_stops),
                padding: const EdgeInsets.all(80),
                maxZoom: 16,
              ),
        initialZoom: 13,
        onTap: (_, p) => _point(p),
      ),
      children: [
        if (!AppVariant.modernInterface)
          TileLayer(
            urlTemplate: OfflineMapsService.routeTileUrl,
            tileProvider: OfflineMapsService.tileProvider(
              offlineOnly: NavigationPreferences.instance.cachedMapOnly,
            ),
            userAgentPackageName: 'com.pulsepath.app',
          ),
        PolylineLayer(
          polylines: [
            if (_stops.length > 1)
              Polyline(
                points: _route?.points ?? _stops,
                color: _route != null || !_roads
                    ? colors.primary
                    : colors.outline,
                strokeWidth: 5,
              ),
          ],
        ),
        MarkerLayer(
          markers: [
            for (var i = 0; i < _stops.length; i++)
              Marker(
                point: _stops[i],
                width: 48,
                height: 48,
                child: Semantics(
                  label: _role(i),
                  button: true,
                  child: GestureDetector(
                    onTap: _busy
                        ? null
                        : () {
                            _replace = i;
                            _refresh();
                          },
                    child: CircleAvatar(
                      backgroundColor: _replace == i
                          ? colors.tertiary
                          : colors.primary,
                      foregroundColor: _replace == i
                          ? colors.onTertiary
                          : colors.onPrimary,
                      child: Text(
                        i == 0
                            ? 'A'
                            : i == _stops.length - 1
                            ? 'B'
                            : '$i',
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const RichAttributionWidget(
          attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
        ),
      ],
    );
    return PopScope(
      canPop: !_busy && !_changed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Новый маршрут'),
          actions: [
            IconButton(
              tooltip: 'Нарисовать маршрут',
              icon: const Icon(Icons.gesture),
              onPressed: _busy
                  ? null
                  : () async {
                      final saved = await Navigator.push<bool>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => RouteGeometryEditorScreen(
                            initialCenter: widget.initialCenter,
                            routingService: widget.routingService,
                          ),
                        ),
                      );
                      if (mounted && saved == true) {
                        _message('Нарисованный маршрут сохранён в библиотеке');
                      }
                    },
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                flex: 3,
                child: MainMapGateway(
                  map: map,
                  title: 'Новый маршрут',
                  controls: _panel,
                  autoOpen: true,
                  footer: _saveButton,
                  keepCamera: true,
                ),
              ),
              Expanded(
                flex: 2,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _panel(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaceSearch extends SearchDelegate<Map<String, dynamic>?> {
  _PlaceSearch() : super(searchFieldLabel: 'Адрес или название места');
  Future<List<Map<String, dynamic>>>? _results;
  @override
  List<Widget> buildActions(BuildContext context) => [
    IconButton(
      tooltip: 'Очистить',
      onPressed: () {
        query = '';
        _results = null;
      },
      icon: const Icon(Icons.close),
    ),
  ];
  @override
  Widget buildLeading(BuildContext context) => IconButton(
    tooltip: 'Назад',
    onPressed: () => close(context, null),
    icon: const Icon(Icons.arrow_back),
  );
  @override
  Widget buildSuggestions(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Text(
      'Введите место и нажмите поиск на клавиатуре. Поиск выполняется через интернет.',
    ),
  );
  @override
  Widget buildResults(BuildContext context) {
    _results ??= GeocodingService().searchPlaces(query, nearbyOnly: false);
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _results,
      builder: (ctx, state) {
        if (state.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (state.hasError) {
          return Center(
            child: TextButton(
              onPressed: () {
                _results = null;
                showResults(context);
              },
              child: const Text('Поиск недоступен. Повторить'),
            ),
          );
        }
        final rows = state.data ?? [];
        if (rows.isEmpty) {
          return const Center(
            child: Text('Места не найдены. Уточните запрос.'),
          );
        }
        return ListView.builder(
          itemCount: rows.length,
          itemBuilder: (ctx, i) => ListTile(
            leading: const Icon(Icons.place_outlined),
            title: Text('${rows[i]['display_name']}'),
            onTap: () => close(context, rows[i]),
          ),
        );
      },
    );
  }

  @override
  void showResults(BuildContext context) {
    _results = null;
    super.showResults(context);
  }
}
