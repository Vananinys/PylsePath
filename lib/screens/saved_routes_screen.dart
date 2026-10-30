import '../widgets/activity_trail_layer.dart';

import 'package:flutter/material.dart';

import '../widgets/section_intro.dart';

import 'package:flutter_map/flutter_map.dart';

import '../data/navigation_preferences.dart';
import '../data/saved_routes_repository.dart';
import '../models/activity_type.dart';
import '../models/saved_route.dart';
import '../models/shared_route.dart';
import '../models/workout_details.dart';
import '../services/offline_maps_service.dart';
import '../services/route_library.dart';
import '../utils/gpx_share.dart';
import '../widgets/route_share_sheet.dart';
import '../widgets/route_trace_preview.dart';
import 'route_builder_screen.dart';

class SavedRoutesScreen extends StatefulWidget {
  const SavedRoutesScreen({super.key});
  @override
  State<SavedRoutesScreen> createState() => _SavedRoutesScreenState();
}

class _SavedRoutesScreenState extends State<SavedRoutesScreen> {
  final _repository = SavedRoutesRepository();
  final _search = TextEditingController();
  bool _loading = true, _favorites = false;
  String? _error, _collection;
  ActivityType? _activity;
  double? _maxKm;
  RouteSort _sort = RouteSort.recent;
  List<SavedRoute> _routes = [];
  final _busy = <String>{};
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final routes = await _repository.getSavedRoutes();
      if (!mounted) return;
      setState(() {
        _routes = routes;
        _loading = false;
        _error = null;
        if (_collection != null &&
            !routes.any((r) => r.collection == _collection)) {
          _collection = null;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Не удалось прочитать маршруты. Повторите загрузку.';
        });
      }
    }
  }

  Future<void> _update(SavedRoute route) async {
    if (!_busy.add(route.localId)) return;
    setState(() {});
    try {
      await _repository.updateRoute(route);
      await _load();
    } catch (_) {
      _message('Не удалось сохранить изменения маршрута');
    } finally {
      if (mounted) {
        setState(() => _busy.remove(route.localId));
      }
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final routes = filterRoutes(
      _routes,
      query: _search.text,
      activity: _activity,
      favorites: _favorites,
      collection: _collection,
      maxKm: _maxKm,
      sort: _sort,
    );
    final collections =
        _routes
            .map((r) => r.collection)
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final activities = _routes.map((r) => r.activityType).toSet();
    const sorts = ['Недавние', 'Короче', 'Длиннее', 'Больше набора'];
    return Scaffold(
      appBar: AppBar(title: const Text('Мои маршруты')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final saved = await Navigator.push<bool>(
            context,
            MaterialPageRoute(builder: (_) => const RouteBuilderScreen()),
          );
          if (saved == true && mounted) await _load();
        },
        icon: const Icon(Icons.add_location_alt_outlined),
        label: const Text('Создать маршрут'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SectionIntro(
                            icon: Icons.route_outlined,
                            eyebrow: 'ВАША КОЛЛЕКЦИЯ',
                            title: 'Ваши маршруты',
                            description: 'Откройте маршрут, чтобы посмотреть детали и начать подготовку. Новый путь создаётся кнопкой внизу.',
                            children: [
                              Text(
                                'Сохранено маршрутов: ${_routes.length}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          if (_error != null)
                            ListTile(
                              title: Text(_error!),
                              trailing: IconButton(
                                tooltip: 'Обновить',
                                onPressed: _load,
                                icon: const Icon(Icons.refresh),
                              ),
                            ),
                          TextField(
                            controller: _search,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              hintText: 'Название, коллекция или заметка',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: _search.text.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: 'Очистить поиск',
                                      icon: const Icon(Icons.close),
                                      onPressed: () => setState(_search.clear),
                                    ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 6,
                            children: [
                              FilterChip(
                                avatar: const Icon(
                                  Icons.star_outline,
                                  size: 18,
                                ),
                                label: const Text('Избранное'),
                                selected: _favorites,
                                onSelected: (value) =>
                                    setState(() => _favorites = value),
                              ),
                              for (final km in [20.0, 50.0, 100.0])
                                FilterChip(
                                  label: Text('До ${km.round()} км'),
                                  selected: _maxKm == km,
                                  onSelected: (value) => setState(
                                    () => _maxKm = value ? km : null,
                                  ),
                                ),
                            ],
                          ),
                          if (activities.length > 1)
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  ChoiceChip(
                                    label: const Text('Все виды'),
                                    selected: _activity == null,
                                    onSelected: (_) =>
                                        setState(() => _activity = null),
                                  ),
                                  for (final a in ActivityType.values.where(
                                    activities.contains,
                                  ))
                                    Padding(
                                      padding: const EdgeInsets.only(left: 6),
                                      child: ChoiceChip(
                                        avatar: Icon(a.icon, size: 16),
                                        label: Text(a.label),
                                        selected: _activity == a,
                                        onSelected: (_) =>
                                            setState(() => _activity = a),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          if (collections.isNotEmpty)
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  ChoiceChip(
                                    label: const Text('Все коллекции'),
                                    selected: _collection == null,
                                    onSelected: (_) =>
                                        setState(() => _collection = null),
                                  ),
                                  for (final name in collections)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 6),
                                      child: ChoiceChip(
                                        label: Text(name),
                                        selected: _collection == name,
                                        onSelected: (_) =>
                                            setState(() => _collection = name),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Найдено: ${routes.length}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                              DropdownButton<RouteSort>(
                                value: _sort,
                                underline: const SizedBox.shrink(),
                                items: [
                                  for (final sort in RouteSort.values)
                                    DropdownMenuItem(
                                      value: sort,
                                      child: Text(sorts[sort.index]),
                                    ),
                                ],
                                onChanged: (sort) {
                                  if (sort != null) {
                                    setState(() => _sort = sort);
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (routes.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.explore_outlined,
                              size: 56,
                              color: Colors.deepOrange,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _routes.isEmpty
                                  ? 'Ваши будущие поездки'
                                  : 'Маршрутов с такими условиями нет',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _routes.isEmpty
                                  ? 'Постройте маршрут на карте или откройте GPX и сохраните его. Линия и подсказки останутся на устройстве.'
                                  : 'Попробуйте другой запрос или сбросьте фильтры.',
                              textAlign: TextAlign.center,
                            ),
                            if (_routes.isNotEmpty)
                              TextButton(
                                onPressed: () => setState(() {
                                  _search.clear();
                                  _activity = null;
                                  _maxKm = null;
                                  _collection = null;
                                  _favorites = false;
                                }),
                                child: const Text('Сбросить фильтры'),
                              ),
                          ],
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      sliver: SliverList.builder(
                        itemCount: routes.length,
                        itemBuilder: (_, index) => _card(routes[index]),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _card(SavedRoute route) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => _details(route),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 84,
                  height: 84,
                  child: RouteTracePreview(
                    points: route.routePoints,
                    segmentStarts: route.workoutDetails.segmentStarts,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        route.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${route.activityType.label} · ${route.distanceKm.toStringAsFixed(1)} км',
                      ),
                      if (route.collection.isNotEmpty)
                        Text(
                          route.collection,
                          style: const TextStyle(color: Colors.deepOrange),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: route.isFavorite
                      ? 'Убрать из избранного'
                      : 'В избранное',
                  onPressed: _busy.contains(route.localId)
                      ? null
                      : () => _update(
                          route.withLibraryDetails(favorite: !route.isFavorite),
                        ),
                  icon: Icon(
                    route.isFavorite ? Icons.star : Icons.star_outline,
                    color: Colors.deepOrange,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.schedule, size: 16),
                    const SizedBox(width: 4),
                    Text(route.displayDuration),
                  ],
                ),
                if (route.elevationGainMeters > 0)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.trending_up, size: 16),
                      const SizedBox(width: 4),
                      Text('${route.elevationGainMeters.round()} м'),
                    ],
                  ),
                const Text(
                  'Трек на устройстве',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
            if (route.routeNotes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  route.routeNotes,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Future<void> _details(SavedRoute route) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * .8,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Text(route.title, style: Theme.of(ctx).textTheme.headlineSmall),
              const SizedBox(height: 12),
              SizedBox(
                height: 240,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: route.routePoints.length < 2
                      ? const Center(
                          child: Text('В этом маршруте нет линии трека'),
                        )
                      : FlutterMap(
                          options: MapOptions(
                            initialCameraFit: CameraFit.bounds(
                              bounds: LatLngBounds.fromPoints(
                                route.routePoints,
                              ),
                              padding: const EdgeInsets.all(24),
                              maxZoom: 17,
                            ),
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
                            ActivityTrailLayer(
                              segments: WorkoutDetails.splitTrack(
                                route.routePoints,
                                route.workoutDetails.segmentStarts,
                              ),
                              activity: route.activityType,
                              transport: route.transportType,
                            ),
                            Align(
                              alignment: Alignment.bottomRight,
                              child: ColoredBox(
                                color: Colors.white70,
                                child: Padding(
                                  padding: EdgeInsets.all(3),
                                  child: Text(
                                    '© OpenStreetMap',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '${route.activityType.label} · ${route.distanceKm.toStringAsFixed(1)} км · ${route.displayDuration}',
              ),
              if (route.elevationGainMeters > 0)
                Text('Набор высоты: ${route.elevationGainMeters.round()} м'),
              if (route.surfaceSummary.isNotEmpty) Text(route.surfaceSummary),
              if (route.routeNotes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(route.routeNotes),
                ),
              const SizedBox(height: 10),
              const Text(
                'Линия маршрута доступна без сети. Фон карты зависит от сохранённых тайлов.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: route.routePoints.length < 2
                    ? null
                    : () => Navigator.pop(ctx, 'open'),
                icon: const Icon(Icons.navigation_outlined),
                label: const Text('Открыть на карте'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(ctx, 'geometry'),
                icon: const Icon(Icons.edit_road_outlined),
                label: const Text('Изменить линию и точки (копия)'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(ctx, 'edit'),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Название, коллекция и заметка'),
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: route.routePoints.length < 2
                        ? null
                        : () => Navigator.pop(ctx, 'gpx'),
                    icon: const Icon(Icons.file_upload_outlined),
                    label: const Text('GPX'),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.pop(ctx, 'share'),
                    icon: const Icon(Icons.people_outline),
                    label: const Text('Друзьям'),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.pop(ctx, 'delete'),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Удалить'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'geometry':
        final saved = await Navigator.push<bool>(
          context,
          MaterialPageRoute(builder: (_) => RouteBuilderScreen(source: route)),
        );
        if (saved == true && mounted) await _load();
      case 'open':
        Navigator.pop(context, route);
      case 'edit':
        await _edit(route);
      case 'gpx':
        try {
          await GpxShare.route(context, route);
        } catch (_) {
          _message('Не удалось подготовить GPX');
        }
      case 'share':
        await showRouteShareSheet(
          context,
          SharedRoute.fromSavedRoute(route, kind: 'route'),
        );
      case 'delete':
        await _remove(route);
    }
  }

  Future<void> _edit(SavedRoute route) async {
    final result = await showDialog<SavedRoute>(
      context: context,
      builder: (_) => _RouteEditor(route: route),
    );
    if (result != null && mounted) {
      await _update(result);
    }
  }

  Future<void> _remove(SavedRoute route) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить маршрут?'),
        content: Text('«${route.title}» будет удалён из библиотеки.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _repository.removeRoute(route);
      await _load();
    } catch (_) {
      _message('Не удалось удалить маршрут');
    }
  }
}

class _RouteEditor extends StatefulWidget {
  const _RouteEditor({required this.route});
  final SavedRoute route;
  @override
  State<_RouteEditor> createState() => _RouteEditorState();
}

class _RouteEditorState extends State<_RouteEditor> {
  late final _title = TextEditingController(text: widget.route.title);
  late final _collection = TextEditingController(text: widget.route.collection);
  late final _notes = TextEditingController(text: widget.route.routeNotes);
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _title.dispose();
    _collection.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Настроить маршрут'),
    content: SingleChildScrollView(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _title,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Название'),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Укажите название' : null,
            ),
            TextFormField(
              controller: _collection,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: 'Коллекция',
                hintText: 'Например, Выходные',
              ),
            ),
            TextFormField(
              controller: _notes,
              maxLines: 3,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: 'Заметка',
                hintText: 'Покрытие, остановки, особенности',
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(
              context,
              widget.route.withLibraryDetails(
                title: _title.text.trim(),
                collection: _collection.text.trim(),
                notes: _notes.text.trim(),
              ),
            );
          }
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
}
