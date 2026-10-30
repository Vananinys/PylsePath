import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../data/navigation_preferences.dart';
import '../data/workout_history_repository.dart';
import '../models/ride_moment.dart';
import '../models/saved_route.dart';
import '../models/workout_details.dart';
import '../services/offline_maps_service.dart';
import '../services/ride_pulse.dart';

const _pulseColor = Color(0xff147d73);

class RidePulseView extends StatefulWidget {
  const RidePulseView({super.key, required this.route, this.onExpandMap});
  final SavedRoute route;
  final VoidCallback? onExpandMap;
  @override
  State<RidePulseView> createState() => _RidePulseViewState();
}

class _RidePulseViewState extends State<RidePulseView> {
  late SavedRoute _route = widget.route;
  late RidePulse _pulse = RidePulse(_route);
  final _map = MapController();
  Timer? _playback;
  double _progress = 0;
  bool _altitude = false, _saving = false, _mapReady = false;
  List<({RideMoment moment, int index, String source})> _memories = [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadMemories());
  }

  Future<void> _loadMemories() async {
    try {
      final rows = await WorkoutHistoryRepository().getWorkoutHistory();
      final memories = <({RideMoment moment, int index, String source})>[];
      for (final previous in rows.reversed.take(60)) {
        if (previous.localId == _route.localId ||
            !previous.dateTime.isBefore(_route.dateTime) ||
            previous.workoutDetails.rideMoments.isEmpty ||
            !RidePulse.matchesRoute(_route, previous))
          continue;
        for (final moment in previous.workoutDetails.rideMoments) {
          if (moment.pointIndex >= previous.routePoints.length) continue;
          final index = _pulse.indexNear(
            previous.routePoints[moment.pointIndex],
          );
          if (index != null)
            memories.add((
              moment: moment,
              index: index,
              source:
                  '${previous.dateTime.day}.${previous.dateTime.month} · ${previous.title}',
            ));
          if (memories.length >= 12) break;
        }
        if (memories.length >= 12) break;
      }
      if (mounted) setState(() => _memories = memories);
    } catch (_) {
      // Current ride stays available when the rest of history cannot be read.
    }
  }

  @override
  void dispose() {
    _playback?.cancel();
    _map.dispose();
    super.dispose();
  }

  void _seek(double value, {bool stop = true}) {
    if (stop) _playback?.cancel();
    setState(() => _progress = value.clamp(0.0, 1.0));
  }

  void _togglePlayback() {
    if (_playback?.isActive == true) {
      _playback?.cancel();
      setState(() {});
      return;
    }
    if (_progress >= 1) _progress = 0;
    _playback = Timer.periodic(const Duration(milliseconds: 180), (_) {
      if (!mounted) return;
      _seek(_progress + .005, stop: false);
      if (_progress >= 1) {
        _playback?.cancel();
        setState(() {});
      }
    });
    setState(() {});
  }

  void _showPlace(int index) {
    _seek(_pulse.progressAtIndex(index));
    if (_mapReady && index < _route.routePoints.length) {
      _map.move(_route.routePoints[index], math.max(_map.camera.zoom, 15));
    }
  }

  IconData _icon(RideMomentKind kind) => switch (kind) {
    RideMomentKind.goodSection => Icons.waves_outlined,
    RideMomentKind.climb => Icons.terrain_outlined,
    RideMomentKind.technical => Icons.alt_route,
    RideMomentKind.rest => Icons.park_outlined,
  };

  Future<void> _addMoment() async {
    if (_saving || !_pulse.canReplay) return;
    _playback?.cancel();
    setState(() {});
    final frame = _pulse.frameAt(_progress);
    final moment = await showModalBottomSheet<RideMoment>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _RideMomentEditor(frame: frame, iconFor: _icon),
    );
    if (!mounted || moment == null) return;
    setState(() => _saving = true);
    try {
      final repository = WorkoutHistoryRepository();
      final updated = await repository.addRideMoment(_route, moment);
      if (!mounted) return;
      setState(() {
        _route = updated;
        _pulse = RidePulse(updated);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Место сохранено. Синхронизация продолжится при наличии интернета.',
          ),
        ),
      );
      unawaited(
        repository
            .retryUnsynced(maxItems: 3)
            .then<void>((_) {}, onError: (Object _, StackTrace __) {}),
      );
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось сохранить отметку. Попробуйте ещё раз.'),
          ),
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _mapView(RidePulseFrame frame) {
    final points = _route.routePoints;
    if (points.isEmpty)
      return const SizedBox(
        height: 140,
        child: Center(
          child: Text('GPS-трек не записан. Показатели заезда сохранены.'),
        ),
      );
    return SizedBox(
      height: 270,
      child: FlutterMap(
        mapController: _map,
        options: MapOptions(
          initialCenter: points.first,
          initialZoom: 15,
          initialCameraFit: points.length > 1
              ? CameraFit.bounds(
                  bounds: LatLngBounds.fromPoints(points),
                  padding: const EdgeInsets.all(30),
                  maxZoom: 17,
                )
              : null,
          onMapReady: () => _mapReady = true,
        ),
        children: [
          ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerLow),
          if (!NavigationPreferences.instance.cachedMapOnly ||
              OfflineMapsService.isAvailable)
            TileLayer(
              urlTemplate: OfflineMapsService.routeTileUrl,
              tileProvider: OfflineMapsService.tileProvider(
                offlineOnly: NavigationPreferences.instance.cachedMapOnly,
              ),
              userAgentPackageName: 'com.example.pulsepath',
            ),
          PolylineLayer(
            polylines: [
              for (final segment in WorkoutDetails.splitTrack(
                points,
                _route.workoutDetails.segmentStarts,
              ))
                if (segment.length > 1)
                  Polyline(
                    points: segment,
                    color: _pulseColor,
                    strokeWidth: 4.5,
                  ),
            ],
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: points.first,
                width: 26,
                height: 26,
                child: const Icon(
                  Icons.trip_origin,
                  color: _pulseColor,
                  size: 23,
                ),
              ),
              Marker(
                point: points.last,
                width: 26,
                height: 26,
                child: const Icon(
                  Icons.flag_rounded,
                  color: Color(0xff34465b),
                  size: 24,
                ),
              ),
              for (final moment in _route.workoutDetails.rideMoments)
                if (moment.pointIndex < points.length)
                  Marker(
                    point: points[moment.pointIndex],
                    width: 38,
                    height: 38,
                    child: GestureDetector(
                      onTap: () => _showPlace(moment.pointIndex),
                      child: Tooltip(
                        message: '${moment.kind.label} · ${moment.note}',
                        child: CircleAvatar(
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surface,
                          child: Icon(
                            _icon(moment.kind),
                            color: _pulseColor,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ),
              if (frame.point case final point?)
                Marker(
                  point: point,
                  width: 24,
                  height: 24,
                  child: Container(
                    decoration: BoxDecoration(
                      color: _pulseColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 4),
                      boxShadow: const [
                        BoxShadow(blurRadius: 8, color: Colors.black26),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          Positioned(
            top: 10,
            right: 10,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              shape: const CircleBorder(),
              child: IconButton(
                tooltip: 'Показать весь маршрут',
                icon: const Icon(Icons.fit_screen),
                onPressed: () {
                  if (_mapReady && points.length > 1)
                    _map.fitCamera(
                      CameraFit.bounds(
                        bounds: LatLngBounds.fromPoints(points),
                        padding: const EdgeInsets.all(30),
                        maxZoom: 17,
                      ),
                    );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final frame = _pulse.frameAt(_progress);
    final sample = frame.sample;
    final theme = Theme.of(context);
    final insights = _pulse.insights;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.route_outlined,
                    color: theme.colorScheme.onSecondaryContainer,
                    size: 18,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'ВАШ ПУЛЬС МАРШРУТА',
                      style: TextStyle(
                        color: theme.colorScheme.onSecondaryContainer,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '${_route.distanceKm.toStringAsFixed(2)} км',
                style: theme.textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_route.displayDuration} движения · ${_route.activityType.label}',
              ),
              const SizedBox(height: 18),
              Text(
                insights.first.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(insights.first.detail),
              if (_route.workoutDetails.effort case final effort?) ...[
                const SizedBox(height: 10),
                Text('Ваше ощущение нагрузки — $effort из 10'),
              ],
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Лента пути',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (widget.onExpandMap != null)
                          IconButton(
                            tooltip: 'Развернуть карту',
                            icon: const Icon(Icons.fullscreen),
                            onPressed: () {
                              _playback?.cancel();
                              setState(() {});
                              widget.onExpandMap?.call();
                            },
                          ),
                      ],
                    ),
                    TextButton.icon(
                      onPressed: _pulse.canReplay && !_saving
                          ? _addMoment
                          : null,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(
                              Icons.add_location_alt_outlined,
                              size: 19,
                            ),
                      label: const Text('Запомнить'),
                    ),
                  ],
                ),
              ),
              _mapView(frame),
              if (_pulse.canReplay) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: _togglePlayback,
                        tooltip: _playback?.isActive == true
                            ? 'Пауза повтора'
                            : 'Повторить маршрут',
                        icon: Icon(
                          _playback?.isActive == true
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill,
                          color: _pulseColor,
                          size: 36,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${(frame.meters / 1000).toStringAsFixed(2)} км',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        sample?.activeSeconds != null
                            ? '≈ ${workoutTime(Duration(seconds: sample!.activeSeconds))} движения'
                            : 'По дистанции',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Slider(
                  value: _progress,
                  onChanged: _seek,
                  activeColor: _pulseColor,
                  semanticFormatterCallback: (p) =>
                      '${(_pulse.meters * p / 1000).toStringAsFixed(2)} километра от старта',
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      Text(
                        sample?.speedKmh == null
                            ? 'Скорость — нет измерения'
                            : '${sample!.speedKmh!.toStringAsFixed(1)} км/ч',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (sample?.altitudeMeters case final altitude?)
                        Text('${altitude.round()} м над уровнем моря'),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Скорость'),
                        selected: !_altitude,
                        onSelected: (_) => setState(() => _altitude = false),
                      ),
                      ChoiceChip(
                        label: const Text('Высота'),
                        selected: _altitude,
                        onSelected: _pulse.hasAltitude
                            ? (_) => setState(() => _altitude = true)
                            : null,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: LayoutBuilder(
                    builder: (context, constraints) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) => _seek(
                        details.localPosition.dx / constraints.maxWidth,
                      ),
                      onHorizontalDragUpdate: (details) => _seek(
                        details.localPosition.dx / constraints.maxWidth,
                      ),
                      child: SizedBox(
                        height: 112,
                        child: CustomPaint(
                          painter: _PulsePainter(
                            _pulse,
                            _progress,
                            _altitude,
                            theme.colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Text(
                    '${_altitude ? 'м · над уровнем моря' : 'км/ч · записанные измерения'} · повтор по дистанции${_pulse.gaps > 0 ? ' · разрывов GPS: ${_pulse.gaps}' : ''}\n${_pulse.hasAltitude ? 'Коснитесь графика, чтобы посмотреть место на карте.' : 'Высота в этом заезде не записана с достаточной точностью.'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (insights.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              children: [
                for (final insight in insights.skip(1))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.insights_outlined,
                      color: _pulseColor,
                    ),
                    title: Text(insight.title),
                    subtitle: Text(insight.detail),
                    trailing: insight.progress == null
                        ? null
                        : const Icon(Icons.chevron_right),
                    onTap: insight.progress == null
                        ? null
                        : () => _seek(insight.progress!),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.bookmarks_outlined,
                    color: _pulseColor,
                    size: 21,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Память маршрута',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Icon(Icons.lock_outline, size: 16),
                ],
              ),
              const SizedBox(height: 8),
              if (_route.workoutDetails.rideMoments.isEmpty)
                const Text(
                  'Выберите место на ленте пути и нажмите «Запомнить». Отметки появятся и при просмотре похожих маршрутов.',
                ),
              for (final moment in _route.workoutDetails.rideMoments)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_icon(moment.kind), color: _pulseColor),
                  title: Text(moment.kind.label),
                  subtitle: Text(
                    '${(moment.distanceMeters / 1000).toStringAsFixed(2)} км${moment.note.isEmpty ? '' : ' · ${moment.note}'}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showPlace(moment.pointIndex),
                ),
              if (_memories.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Вы отмечали раньше на похожем треке',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                for (final memory in _memories)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_icon(memory.moment.kind)),
                    title: Text(
                      memory.moment.note.isEmpty
                          ? memory.moment.kind.label
                          : memory.moment.note,
                    ),
                    subtitle: Text(memory.source),
                    onTap: () => _showPlace(memory.index),
                  ),
              ],
              const SizedBox(height: 8),
              Text(
                'Личные отметки не попадают в GPX, чат и публикации.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RideMomentEditor extends StatefulWidget {
  const _RideMomentEditor({required this.frame, required this.iconFor});
  final RidePulseFrame frame;
  final IconData Function(RideMomentKind) iconFor;

  @override
  State<_RideMomentEditor> createState() => _RideMomentEditorState();
}

class _RideMomentEditorState extends State<_RideMomentEditor> {
  final _note = TextEditingController();
  RideMomentKind _kind = RideMomentKind.goodSection;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(
      20,
      24,
      20,
      24 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Запомнить это место',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          '${(widget.frame.meters / 1000).toStringAsFixed(2)} км от старта · личная отметка',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final kind in RideMomentKind.values)
              ChoiceChip(
                avatar: Icon(widget.iconFor(kind), size: 18),
                label: Text(kind.label),
                selected: _kind == kind,
                onSelected: (_) => setState(() => _kind = kind),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          maxLength: 280,
          minLines: 2,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Что хотите вспомнить?',
            hintText: 'Например: удобное место для короткой остановки',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.bookmark_add_outlined),
          onPressed: () => Navigator.pop(
            context,
            RideMoment(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              kind: _kind,
              pointIndex: widget.frame.pointIndex,
              distanceMeters: widget.frame.meters,
              note: _note.text.trim(),
            ),
          ),
          label: const Text('Сохранить место'),
        ),
      ],
    ),
  );
}

class _PulsePainter extends CustomPainter {
  _PulsePainter(this.pulse, this.progress, this.altitude, this.gridColor);
  final RidePulse pulse;
  final double progress;
  final bool altitude;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 1; i <= 3; i++)
      canvas.drawLine(
        Offset(0, size.height * i / 4),
        Offset(size.width, size.height * i / 4),
        paint,
      );
    double? value(WorkoutSample s) => altitude ? s.altitudeMeters : s.speedKmh;
    final values = pulse.samples.map(value).whereType<double>().toList();
    if (values.length >= 2 && pulse.meters > 0) {
      final min = altitude ? values.reduce(math.min) : 0.0;
      final max = values.reduce(math.max);
      final range = math.max(max - min, 1);
      final path = Path();
      var open = false;
      WorkoutSample? last;
      for (final sample in pulse.samples) {
        final y = value(sample);
        if (y == null) {
          open = false;
          last = null;
          continue;
        }
        if (last != null &&
            (sample.activeSeconds - last.activeSeconds > 30 ||
                ((sample.elapsedSeconds ?? sample.activeSeconds) -
                            (last.elapsedSeconds ?? last.activeSeconds)) -
                        (sample.activeSeconds - last.activeSeconds) >
                    15))
          open = false;
        final point = Offset(
          (sample.distanceMeters / pulse.meters).clamp(0, 1) * size.width,
          size.height - 8 - (y - min) / range * (size.height - 16),
        );
        if (open) {
          path.lineTo(point.dx, point.dy);
        } else {
          path.moveTo(point.dx, point.dy);
        }
        open = true;
        last = sample;
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = _pulseColor
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.drawLine(
      Offset(size.width * progress, 0),
      Offset(size.width * progress, size.height),
      Paint()
        ..color = const Color(0xff34465b)
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_PulsePainter old) =>
      old.progress != progress ||
      old.altitude != altitude ||
      old.pulse != pulse ||
      old.gridColor != gridColor;
}
