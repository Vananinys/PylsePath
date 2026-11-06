import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';

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
  String? _error;
  int? _replace;
  ActivityType _activity = ActivityType.cycling;
  MapController get _map => PrimaryMapNavigation.instance.resolve(_localMap);
  bool get _owned => UserScope.currentUserId() == _owner;
  bool get _canSave =>
      !_busy && _stops.length >= 2 && (!_roads || _route != null);
  @override
  void dispose() {
    _localMap.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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
    if (_busy || !_owned) return;
    _undo.add(_snapshot());
    if (_undo.length > 30) _undo.removeAt(0);
    _redo.clear();
    edit();
    _changed = true;
    _replace = null;
    await _calculate();
  }

  Future<void> _calculate() async {
    _route = null;
    _error = null;
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

  Future<void> _point(LatLng point, [String? name]) async {
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
        _stops.add(point);
        _labels.add(label);
      }
    });
  }

  Future<void> _history(bool redo) async {
    if (_busy || !_owned) return;
    final from = redo ? _redo : _undo, to = redo ? _undo : _redo;
    if (from.isEmpty) return;
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
    await _calculate();
  }

  Future<void> _locate() async {
    if (_busy) return;
    _busy = true;
    _refresh();
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied)
        permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _message('Разрешите геопозицию или выберите точку на карте.');
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          timeLimit: Duration(seconds: 15),
        ),
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
    final name = TextEditingController(text: 'Мой маршрут');
    final notes = TextEditingController();
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
                  controller: name,
                  maxLength: 120,
                  decoration: const InputDecoration(labelText: 'Название'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Введите название' : null,
                ),
                TextFormField(
                  controller: notes,
                  maxLength: 2000,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Заметка · необязательно',
                  ),
                ),
                FilledButton(
                  onPressed: () {
                    if (form.currentState!.validate())
                      Navigator.pop(sheet, (
                        title: name.text.trim(),
                        notes: notes.text,
                      ));
                  },
                  child: const Text('Сохранить'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Controllers belong to the sheet until its closing animation completes.
    if (!mounted || !_owned || details == null) return;
    _busy = true;
    _refresh();
    try {
      await SavedRoutesRepository().addRoute(
        _geometry.plannedCopy(
          title: details.title,
          notes: details.notes,
          activity: _activity,
        ),
      );
      if (mounted && _owned) {
        _changed = false;
        Navigator.of(context).pop(true);
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
        content: const Text('Маршрут ещё не сохранён.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Продолжить создание'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Выйти без сохранения'),
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
  Widget _panel(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _stops.isEmpty
                    ? 'Куда отправимся?'
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
            onReorder: (oldIndex, newIndex) {
              if (_busy) return;
              _change(() {
                if (newIndex > oldIndex) newIndex--;
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
            'Следующее нажатие добавит новую точку в конец пути. Для остановки по пути измените порядок в списке.',
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
                    : () => _point(_stops.first, _labels.first),
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
        FilledButton.icon(
          onPressed: _canSave ? _save : null,
          icon: const Icon(Icons.bookmark_add_outlined),
          label: const Text('Сохранить маршрут'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Preserve precise editing of imported/recorded tracks and all legacy tools.
    if (widget.source != null)
      return RouteGeometryEditorScreen(
        source: widget.source,
        initialCenter: widget.initialCenter,
        routingService: widget.routingService,
      );
    final colors = Theme.of(context).colorScheme;
    final map = FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: widget.initialCenter ?? const LatLng(55.75, 37.61),
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
        appBar: AppBar(title: const Text('Новый маршрут')),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                flex: 3,
                child: MainMapGateway(
                  map: map,
                  title: 'Новый маршрут',
                  controls: _panel,
                  autoOpen: false,
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
      children: [
        if ((!NavigationPreferences.instance.cachedMapOnly ||
                OfflineMapsService.isAvailable) &&
            !AppVariant.modernInterface)
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
              _draft.starts,
            ))
              Polyline(
                points: segment,
                color: _roadPreview != null ? scheme.outline : scheme.primary,
                strokeWidth: 5,
              ),
            if (_rawStroke != null && _smooth)
              Polyline(
                points: _rawStroke!,
                color: scheme.outline.withValues(alpha: .65),
                strokeWidth: 2,
              ),
            if (stroke != null)
              Polyline(
                points: [
                  if (_connectStroke && points.isNotEmpty) points.last,
                  ...stroke,
                ],
                color: Colors.teal,
                strokeWidth: 5,
              ),
            if (_roadPreview != null)
              Polyline(
                points: _roadPreview!.points,
                color: Colors.teal,
                strokeWidth: 6,
              ),
          ],
        ),
        MarkerLayer(
          markers: [
            for (final index in {
              if (points.isNotEmpty) 0,
              if (points.length > 1) points.length - 1,
              if (_selected >= 0 && _selected < points.length) _selected,
            })
              Marker(
                point: points[index],
                width: 38,
                height: 38,
                child: Tooltip(
                  message: 'Точка ${index + 1}',
                  child: Icon(
                    index == 0 ? Icons.trip_origin : Icons.location_on,
                    color: index == _selected
                        ? scheme.secondary
                        : scheme.primary,
                    size: 32,
                  ),
                ),
              ),
          ],
        ),
        if (AppVariant.routeDrawing &&
            _action == _PointAction.draw &&
            !_busy &&
            _rawStroke == null &&
            _roadPreview == null)
          RouteDrawingLayer(
            onStroke: _receiveStroke,
            onLimit: () => _message(
              'Рисунок слишком длинный. Нарисуйте маршрут несколькими частями.',
            ),
          ),
        const RichAttributionWidget(
          attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
        ),
      ],
    );
  }

  Widget _details() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Сохраните свой маршрут',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          'Название, вид активности и заметка — всё в одном месте.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          enabled: !_busy,
          maxLength: 120,
          onChanged: (_) => setState(() => _changed = true),
          decoration: const InputDecoration(
            labelText: 'Название маршрута',
            prefixIcon: Icon(Icons.edit_road_outlined),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<ActivityType>(
          isExpanded: true,
          initialValue: _activity,
          decoration: const InputDecoration(
            labelText: 'Вид активности',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final activity in ActivityType.values)
              DropdownMenuItem(value: activity, child: Text(activity.label)),
          ],
          onChanged: _busy
              ? null
              : (value) => setState(() {
                  _activity = value!;
                  _draft = RouteEditState(_draft.points, starts: _draft.starts);
                  _roadPreview = null;
                  _changed = true;
                }),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _notes,
          enabled: !_busy,
          maxLength: 2000,
          minLines: 1,
          maxLines: 3,
          onChanged: (_) => setState(() => _changed = true),
          decoration: const InputDecoration(
            labelText: 'Заметка (необязательно)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed:
              _busy ||
                  _draft.points.length < 2 ||
                  _rawStroke != null ||
                  _roadPreview != null
              ? null
              : _save,
          icon: const Icon(Icons.bookmark_add_outlined),
          label: Text(_busy ? 'Сохранение…' : 'Сохранить отдельный маршрут'),
        ),
        if (_rawStroke != null || _roadPreview != null)
          const Text('Сначала подтвердите или отмените предпросмотр на карте.'),
        const SizedBox(height: 8),
        Text(
          _draft.estimatedSeconds == null
              ? 'Свободный трек: проходимость не проверена, время не рассчитано.'
              : 'По дорогам · около ${_draft.estimatedSeconds! ~/ 60} мин. Учитывайте реальные ограничения на месте.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && !_changed,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !_busy) _leave();
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('Мой маршрут')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              flex: 4,
              child: MainMapGateway(
                controls: (_) => _mapTools(),
                keepCamera: widget.source == null && _draft.points.isEmpty,
                title: 'Рисуйте свой маршрут',
                autoOpen: true,
                map: _editorMap(context),
              ),
            ),
            Expanded(flex: 3, child: _details()),
          ],
        ),
      ),
    ),
  );
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
        if (state.connectionState != ConnectionState.done)
          return const Center(child: CircularProgressIndicator());
        if (state.hasError)
          return Center(
            child: TextButton(
              onPressed: () {
                _results = null;
                showResults(context);
              },
              child: const Text('Поиск недоступен. Повторить'),
            ),
          );
        final rows = state.data ?? [];
        if (rows.isEmpty)
          return const Center(
            child: Text('Места не найдены. Уточните запрос.'),
          );
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
