import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/route_edit_state.dart';
import '../models/saved_route.dart';
import '../models/activity_type.dart';
import '../models/workout_details.dart';
import '../data/navigation_preferences.dart';
import '../data/saved_routes_repository.dart';
import '../data/user_scope.dart';
import '../services/offline_maps_service.dart';
import '../services/routing_service.dart';

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

enum _PointAction { add, select, move }

class _RouteBuilderScreenState extends State<RouteBuilderScreen> {
  late RouteEditState _draft = RouteEditState(
    widget.source?.routePoints ?? [],
    starts: widget.source?.workoutDetails.segmentStarts ?? const [0],
    steps: widget.source?.navigationSteps ?? const [],
  );
  final _undo = <RouteEditState>[], _redo = <RouteEditState>[];
  final _map = MapController();
  final _owner = UserScope.currentUserId();
  late final _repository = SavedRoutesRepository();
  late final _name = TextEditingController(
    text: widget.source == null
        ? 'Мой маршрут'
        : '${widget.source!.title} — копия',
  );
  late final _notes = TextEditingController(
    text: widget.source?.routeNotes ?? '',
  );
  late ActivityType _activity =
      widget.source?.activityType ?? ActivityType.cycling;
  _PointAction _action = _PointAction.add;
  int _selected = -1;
  bool _busy = false, _changed = false;

  @override
  void dispose() {
    _map.dispose();
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  void _apply(RouteEditState next) {
    _undo.add(_draft);
    if (_undo.length > 30) _undo.removeAt(0);
    setState(() {
      _draft = next;
      _redo.clear();
      _changed = true;
      _selected = next.points.isEmpty
          ? -1
          : _selected.clamp(0, next.points.length - 1);
    });
  }

  void _edit(RouteEditState Function() action) {
    try {
      _apply(action());
    } catch (_) {
      _message('Нельзя выполнить действие для этого участка');
    }
  }

  void _tap(LatLng point) {
    if (_busy) return;
    if (_action == _PointAction.add) {
      final after = _selected < 0 ? _draft.points.length - 1 : _selected;
      _edit(() => _draft.insert(after, point));
      setState(
        () => _selected = (after + 1).clamp(0, _draft.points.length - 1),
      );
    } else if (_action == _PointAction.move && _selected >= 0) {
      _edit(() => _draft.move(_selected, point));
    } else if (_draft.points.isNotEmpty) {
      const measure = Distance();
      var index = 0, best = double.infinity;
      for (var i = 0; i < _draft.points.length; i++) {
        final distance = measure(point, _draft.points[i]);
        if (distance < best) {
          best = distance;
          index = i;
        }
      }
      setState(() => _selected = index);
    }
  }

  Future<void> _trim() async {
    if (_draft.points.length < 3) return;
    var range = RangeValues(0, (_draft.points.length - 1).toDouble());
    final result = await showModalBottomSheet<RangeValues>(
      context: context,
      useSafeArea: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, change) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Оставить участок в новой копии'),
              Text('Точки ${range.start.round() + 1}–${range.end.round() + 1}'),
              RangeSlider(
                values: range,
                max: (_draft.points.length - 1).toDouble(),
                divisions: (_draft.points.length - 1).clamp(1, 1000),
                onChanged: (value) => change(() => range = value),
              ),
              FilledButton(
                onPressed: range.end.round() - range.start.round() < 1
                    ? null
                    : () => Navigator.pop(sheet, range),
                child: const Text('Оставить участок'),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted && result != null) {
      _edit(() => _draft.trim(result.start.round(), result.end.round()));
    }
  }

  Future<void> _roads() async {
    if (_draft.segmentCount > 1 || _draft.points.length < 2) {
      _message('Выберите один непрерывный участок из двух или более точек');
      return;
    }
    var controls = _draft;
    if (controls.points.length > 10) {
      final agreed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Выделить 10 контрольных точек?'),
          content: const Text(
            'Сервис перестроит путь между контрольными точками. Геометрия копии изменится; исходная поездка останется прежней.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Перестроить'),
            ),
          ],
        ),
      );
      if (!mounted || agreed != true) return;
      controls = controls.controlPoints();
    }
    setState(() => _busy = true);
    try {
      final result = await (widget.routingService ?? RoutingService())
          .buildRoute(
            start: controls.points.first,
            end: controls.points.last,
            via: controls.points.sublist(1, controls.points.length - 1),
            activity: _activity,
          );
      if (!mounted || UserScope.currentUserId() != _owner) return;
      _apply(
        RouteEditState(
          result.points,
          estimatedSeconds: (result.durationMin * 60).round(),
          steps: result.steps,
          controls: controls.points,
        ),
      );
    } catch (_) {
      if (mounted) {
        _message(
          'Не удалось построить по дорогам. Предыдущая линия сохранена.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (UserScope.currentUserId() != _owner) throw StateError('account');
      final route = _draft.plannedCopy(
        title: _name.text,
        activity: _activity,
        notes: _notes.text,
        collection: widget.source?.collection ?? '',
      );
      await _repository.addRoute(route);
      if (mounted) {
        setState(() => _changed = false);
        Navigator.pop(context, true);
      }
    } catch (_) {
      if (mounted) {
        _message(
          'Не удалось сохранить. Нужно название до 120 символов и минимум две точки.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Закрыть без сохранения?'),
        content: const Text(
          'Изменения в редакторе не сохранятся. Исходный маршрут останется прежним.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Продолжить'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
    if (mounted && leave == true) {
      setState(() => _changed = false);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = _draft.points;
    final center = points.isEmpty
        ? widget.initialCenter ?? const LatLng(55.75, 37.61)
        : points.first;
    return PopScope(
      canPop: !_busy && !_changed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Конструктор маршрута')),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                flex: 3,
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: center,
                    initialZoom: 13,
                    initialCameraFit: points.length < 2
                        ? null
                        : CameraFit.bounds(
                            bounds: LatLngBounds.fromPoints(points),
                            padding: const EdgeInsets.all(24),
                            maxZoom: 16,
                          ),
                    onTap: (_, point) => _tap(point),
                  ),
                  children: [
                    if (!NavigationPreferences.instance.cachedMapOnly ||
                        OfflineMapsService.isAvailable)
                      TileLayer(
                        urlTemplate: OfflineMapsService.routeTileUrl,
                        tileProvider: OfflineMapsService.tileProvider(
                          offlineOnly:
                              NavigationPreferences.instance.cachedMapOnly,
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
                            color: Colors.deepOrange,
                            strokeWidth: 4,
                          ),
                      ],
                    ),
                    MarkerLayer(
                      markers: [
                        for (final index in {
                          if (points.isNotEmpty) 0,
                          if (points.length > 1) points.length - 1,
                          if (_selected >= 0) _selected,
                        })
                          Marker(
                            point: points[index],
                            width: 38,
                            height: 38,
                            child: Tooltip(
                              message: 'Точка ${index + 1}',
                              child: Icon(
                                Icons.location_on,
                                color: index == _selected
                                    ? Colors.blue
                                    : Colors.deepOrange,
                                size: 36,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const RichAttributionWidget(
                      attributions: [
                        TextSourceAttribution('© OpenStreetMap contributors'),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${points.length} точек · ${(_draft.meters / 1000).toStringAsFixed(2)} км · ${_draft.segmentCount} участков',
                      ),
                      Text(
                        _draft.estimatedSeconds == null
                            ? 'Линия без проверки дорог. Время не рассчитано.'
                            : 'По дорогам · примерно ${_draft.estimatedSeconds! ~/ 60} мин',
                      ),
                      const Text(
                        'Нажмите на карту. «Выбрать» находит ближайшую точку; «Перенести» перемещает выбранную. Исходник не изменяется.',
                        style: TextStyle(fontSize: 12),
                      ),
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final action in _PointAction.values)
                            ChoiceChip(
                              label: Text(
                                [
                                  'Добавлять',
                                  'Выбрать',
                                  'Перенести',
                                ][action.index],
                              ),
                              selected: _action == action,
                              onSelected: _busy
                                  ? null
                                  : (_) => setState(() => _action = action),
                            ),
                        ],
                      ),
                      if (points.isNotEmpty)
                        Row(
                          children: [
                            Expanded(
                              child: Slider(
                                value: _selected
                                    .clamp(0, points.length - 1)
                                    .toDouble(),
                                max: (points.length - 1)
                                    .clamp(1, 100000)
                                    .toDouble(),
                                onChanged: _busy
                                    ? null
                                    : (value) => setState(
                                        () => _selected = value.round().clamp(
                                          0,
                                          points.length - 1,
                                        ),
                                      ),
                              ),
                            ),
                            Text('${_selected + 1}/${points.length}'),
                          ],
                        ),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          IconButton(
                            tooltip: 'Отменить изменение',
                            onPressed: _busy || _undo.isEmpty
                                ? null
                                : () => setState(() {
                                    _redo.add(_draft);
                                    _draft = _undo.removeLast();
                                    _selected = _draft.points.isEmpty ? -1 : 0;
                                    _changed = true;
                                  }),
                            icon: const Icon(Icons.undo),
                          ),
                          IconButton(
                            tooltip: 'Повторить изменение',
                            onPressed: _busy || _redo.isEmpty
                                ? null
                                : () => setState(() {
                                    _undo.add(_draft);
                                    _draft = _redo.removeLast();
                                    _selected = _draft.points.isEmpty ? -1 : 0;
                                    _changed = true;
                                  }),
                            icon: const Icon(Icons.redo),
                          ),
                          TextButton(
                            onPressed: _busy || _selected < 0
                                ? null
                                : () => _edit(() => _draft.remove(_selected)),
                            child: const Text('Убрать точку'),
                          ),
                          TextButton(
                            onPressed:
                                _busy ||
                                    _selected <= 0 ||
                                    points.length > 32 ||
                                    _draft.segmentCount > 1
                                ? null
                                : () {
                                    _edit(
                                      () => _draft.reorder(
                                        _selected,
                                        _selected - 1,
                                      ),
                                    );
                                    setState(() => _selected--);
                                  },
                            child: const Text('Раньше'),
                          ),
                          TextButton(
                            onPressed:
                                _busy ||
                                    _selected < 0 ||
                                    _selected >= points.length - 1 ||
                                    points.length > 32 ||
                                    _draft.segmentCount > 1
                                ? null
                                : () {
                                    _edit(
                                      () => _draft.reorder(
                                        _selected,
                                        _selected + 1,
                                      ),
                                    );
                                    setState(() => _selected++);
                                  },
                            child: const Text('Позже'),
                          ),
                          TextButton(
                            onPressed: _busy || points.isEmpty
                                ? null
                                : () => _edit(_draft.reversed),
                            child: const Text('Обратно'),
                          ),
                          TextButton(
                            onPressed:
                                _busy ||
                                    points.length < 2 ||
                                    _draft.segmentCount > 1
                                ? null
                                : () => _edit(_draft.closeLoop),
                            child: const Text('Замкнуть круг'),
                          ),
                          TextButton(
                            onPressed: _busy || points.length < 3
                                ? null
                                : _trim,
                            child: const Text('Обрезать'),
                          ),
                          TextButton(
                            onPressed:
                                _busy ||
                                    _draft.segmentCount > 1 ||
                                    points.length <= 10
                                ? null
                                : () => _edit(_draft.controlPoints),
                            child: const Text('10 контрольных точек'),
                          ),
                          OutlinedButton(
                            onPressed: _busy ? null : _roads,
                            child: const Text('По дорогам'),
                          ),
                        ],
                      ),
                      TextField(
                        controller: _name,
                        enabled: !_busy,
                        maxLength: 120,
                        onChanged: (_) => setState(() => _changed = true),
                        decoration: const InputDecoration(
                          labelText: 'Название новой копии',
                        ),
                      ),
                      DropdownButtonFormField<ActivityType>(
                        isExpanded: true,
                        initialValue: _activity,
                        items: [
                          for (final activity in ActivityType.values)
                            DropdownMenuItem(
                              value: activity,
                              child: Text(activity.label),
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) => setState(() {
                                _activity = value!;
                                _draft = RouteEditState(
                                  _draft.points,
                                  starts: _draft.starts,
                                );
                                _changed = true;
                              }),
                      ),
                      TextField(
                        controller: _notes,
                        enabled: !_busy,
                        maxLength: 2000,
                        maxLines: 2,
                        onChanged: (_) => setState(() => _changed = true),
                        decoration: const InputDecoration(labelText: 'Заметка'),
                      ),
                      FilledButton.icon(
                        onPressed: _busy || points.length < 2 ? null : _save,
                        icon: const Icon(Icons.save_outlined),
                        label: Text(
                          _busy ? 'Подождите…' : 'Сохранить отдельный маршрут',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
