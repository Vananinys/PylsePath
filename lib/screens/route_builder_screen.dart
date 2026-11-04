import '../config/app_variant.dart';
import '../widgets/primary_map_portal.dart';
import '../widgets/route_drawing_layer.dart';

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

enum _PointAction { add, select, move, draw, pan }

class _RouteBuilderScreenState extends State<RouteBuilderScreen> {
  late RouteEditState _draft = RouteEditState(
    widget.source?.routePoints ?? [],
    starts: widget.source?.workoutDetails.segmentStarts ?? const [0],
    steps: widget.source?.navigationSteps ?? const [],
  );
  final _undo = <RouteEditState>[], _redo = <RouteEditState>[];
  final _localMap = MapController();
  MapController get _map => PrimaryMapNavigation.instance.resolve(_localMap);
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
  List<LatLng>? _rawStroke, _smoothStroke;
  bool _smooth = true, _connectStroke = false;
  RouteEditState? _roadPreview;

  void _receiveStroke(List<LatLng> raw, List<LatLng> smooth) {
    if (_busy || UserScope.currentUserId() != _owner) return;
    if (_draft.points.length + smooth.length > 100000 ||
        raw.any((p) => !RoutingService.validPoint(p)) ||
        smooth.any((p) => !RoutingService.validPoint(p))) {
      _message(
        'Не удалось добавить этот рисунок. Попробуйте более короткий участок.',
      );
      return;
    }
    setState(() {
      _rawStroke = raw;
      _changed = true;
      _smoothStroke = smooth;
      _connectStroke =
          _draft.points.isNotEmpty &&
          const Distance()(_draft.points.last, raw.first) < 30;
      _action = _PointAction.pan;
    });
    PrimaryMapNavigation.instance.refresh();
  }

  void _acceptStroke() {
    final stroke = _smooth ? _smoothStroke : _rawStroke;
    if (stroke == null) return;
    if (!_edit(() => _draft.appendStroke(stroke, connect: _connectStroke))) {
      return;
    }
    setState(() {
      _rawStroke = null;
      _smoothStroke = null;
      _action = _PointAction.draw;
    });
    PrimaryMapNavigation.instance.refresh();
  }

  @override
  void dispose() {
    _localMap.dispose();
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

  bool _edit(RouteEditState Function() action) {
    try {
      _apply(action());
      return true;
    } catch (_) {
      _message('Нельзя выполнить действие для этого участка');
      return false;
    }
  }

  void _tap(LatLng point) {
    if (_busy) return;
    if (_action == _PointAction.draw ||
        _action == _PointAction.pan ||
        _rawStroke != null ||
        _roadPreview != null) {
      return;
    }
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
            'Сохраним начало, конец и заметные повороты. Сервис предложит путь между ними; сравните его с рисунком перед применением.',
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
      setState(
        () => _roadPreview = RouteEditState(
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

  Widget _mapTools() {
    final scheme = Theme.of(context).colorScheme;
    final pending = _rawStroke != null || _roadPreview != null;
    final stroke = _smooth ? _smoothStroke : _rawStroke;
    final shownMeters =
        _roadPreview?.meters ??
        (_draft.meters +
            (stroke == null ? 0 : RouteEditState(stroke).meters) +
            (stroke != null && _connectStroke && _draft.points.isNotEmpty
                ? const Distance()(_draft.points.last, stroke.first)
                : 0));
    final shownPoints =
        _roadPreview?.points.length ??
        _draft.points.length + (stroke?.length ?? 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                Icons.route_rounded,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${(shownMeters / 1000).toStringAsFixed(2)} км',
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    pending
                        ? '$shownPoints точек · предпросмотр'
                        : '${_draft.points.length} точек · ${_draft.segmentCount} участков',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Отменить изменение',
              onPressed: _busy || pending || _undo.isEmpty
                  ? null
                  : () => setState(() {
                      _redo.add(_draft);
                      _draft = _undo.removeLast();
                      _selected = _draft.points.isEmpty ? -1 : 0;
                      _changed = true;
                    }),
              icon: const Icon(Icons.undo_rounded),
            ),
            IconButton(
              tooltip: 'Повторить изменение',
              onPressed: _busy || pending || _redo.isEmpty
                  ? null
                  : () => setState(() {
                      _undo.add(_draft);
                      _draft = _redo.removeLast();
                      _selected = _draft.points.isEmpty ? -1 : 0;
                      _changed = true;
                    }),
              icon: const Icon(Icons.redo_rounded),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (!pending) ...[
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (AppVariant.routeDrawing)
                ChoiceChip(
                  avatar: const Icon(Icons.gesture_rounded, size: 18),
                  label: const Text('Рисовать'),
                  selected: _action == _PointAction.draw,
                  onSelected: _busy
                      ? null
                      : (_) => setState(() => _action = _PointAction.draw),
                ),
              ChoiceChip(
                avatar: const Icon(Icons.add_location_alt_outlined, size: 18),
                label: const Text('Точки'),
                selected: _action == _PointAction.add,
                onSelected: _busy
                    ? null
                    : (_) => setState(() => _action = _PointAction.add),
              ),
              ChoiceChip(
                avatar: const Icon(Icons.pan_tool_outlined, size: 18),
                label: const Text('Карта'),
                selected: _action == _PointAction.pan,
                onSelected: _busy
                    ? null
                    : (_) => setState(() => _action = _PointAction.pan),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _action == _PointAction.draw
                ? 'Проведите пальцем по карте. Затем сравните исходную и плавную линии.'
                : _action == _PointAction.pan
                ? 'Перемещайте и масштабируйте карту. Выберите «Рисовать» или «Точки», чтобы продолжить.'
                : 'Нажимайте на карту, чтобы добавить точки. Отменить действие можно стрелкой сверху.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed:
                _busy || _draft.points.length < 2 || _draft.segmentCount > 1
                ? null
                : _roads,
            icon: const Icon(Icons.alt_route_rounded),
            label: Text(_busy ? 'Построение…' : 'Предложить путь по дорогам'),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Инструменты маршрута'),
            subtitle: const Text('Точки, круг, направление и обрезка'),
            children: [_advancedTools()],
          ),
          const Text(
            'Завершили линию? Нажмите «Готово» сверху, затем задайте название и сохраните маршрут.',
            style: TextStyle(fontSize: 12),
          ),
        ],
        if (_rawStroke != null) ...[
          const Text(
            'Предпросмотр рисунка',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Плавная линия'),
            subtitle: const Text('Сравните с исходным рисунком'),
            value: _smooth,
            onChanged: (v) => setState(() => _smooth = v),
          ),
          if (_draft.points.isNotEmpty)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Соединить с концом маршрута'),
              subtitle: const Text('Выключите, чтобы сохранить разрыв'),
              value: _connectStroke,
              onChanged: (v) => setState(() => _connectStroke = v),
            ),
          FilledButton.icon(
            onPressed: _acceptStroke,
            icon: const Icon(Icons.check_rounded),
            label: const Text('Добавить линию'),
          ),
          TextButton(
            onPressed: () => setState(() {
              _rawStroke = null;
              _smoothStroke = null;
              _action = _PointAction.draw;
            }),
            child: const Text('Нарисовать заново'),
          ),
          const Text(
            'Свободная линия не проверяет проходимость и ограничения дорог.',
            style: TextStyle(fontSize: 12),
          ),
        ],
        if (_roadPreview case final preview?) ...[
          const Text(
            'Предпросмотр пути по дорогам',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            '${(preview.meters / 1000).toStringAsFixed(2)} км · около ${(preview.estimatedSeconds ?? 0) ~/ 60} мин',
          ),
          const Text(
            'Бирюзовая линия — предложение сервиса. Исходная линия остаётся на карте для сравнения.',
          ),
          FilledButton.icon(
            onPressed: () {
              _apply(preview);
              setState(() => _roadPreview = null);
            },
            icon: const Icon(Icons.check),
            label: const Text('Применить маршрут'),
          ),
          TextButton(
            onPressed: () => setState(() => _roadPreview = null),
            child: const Text('Оставить исходную линию'),
          ),
        ],
      ],
    );
  }

  Widget _advancedTools() {
    final points = _draft.points;
    return Column(
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
            for (final action in [
              _PointAction.add,
              _PointAction.select,
              _PointAction.move,
            ])
              ChoiceChip(
                label: Text(
                  ['Добавлять', 'Выбрать', 'Перенести'][action.index],
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
                  value: _selected.clamp(0, points.length - 1).toDouble(),
                  max: (points.length - 1).clamp(1, 100000).toDouble(),
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
                      _edit(() => _draft.reorder(_selected, _selected - 1));
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
                      _edit(() => _draft.reorder(_selected, _selected + 1));
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
              onPressed: _busy || points.length < 2 || _draft.segmentCount > 1
                  ? null
                  : () => _edit(_draft.closeLoop),
              child: const Text('Замкнуть круг'),
            ),
            TextButton(
              onPressed: _busy || points.length < 3 ? null : _trim,
              child: const Text('Обрезать'),
            ),
            TextButton(
              onPressed: _busy || _draft.segmentCount > 1 || points.length <= 10
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
        const Text(
          'Нажмите «Готово», чтобы вернуться к названию и сохранению маршрута.',
        ),
      ],
    );
  }

  FlutterMap _editorMap(BuildContext context) {
    final points = _draft.points;
    final scheme = Theme.of(context).colorScheme;
    final stroke = _smooth ? _smoothStroke : _rawStroke;
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: points.isEmpty
            ? widget.initialCenter ?? const LatLng(55.75, 37.61)
            : points.first,
        initialZoom: 13,
        initialCameraFit: points.length < 2
            ? null
            : CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(points),
                padding: const EdgeInsets.all(32),
                maxZoom: 16,
              ),
        onTap: (_, point) => _tap(point),
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
