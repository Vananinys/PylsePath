import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../data/user_scope.dart';
import '../data/workout_history_repository.dart';
import '../models/saved_route.dart';
import '../services/heatmap_explorer.dart';
import '../services/training_heatmap.dart';

const heatPalettes = <List<Color>>[
  [Color(0xFF5C1AFF), Color(0xFFE73578), Color(0xFFFF982A), Color(0xFFFFFFB0)],
  [Color(0xFF123BB8), Color(0xFF008FFF), Color(0xFF25EBEB), Color(0xFFE8FFFF)],
  [Color(0xFF972000), Color(0xFFFF3E16), Color(0xFFFFB320), Color(0xFFFFFFCF)],
];

class HeatmapPathLayer extends StatefulWidget {
  const HeatmapPathLayer({
    super.key,
    this.personal = true,
    this.public = false,
    this.filter = const HeatmapFilter(),
    this.palette = 0,
    this.opacity = .85,
    this.width = 5,
    this.revision = 0,
    this.rides,
    this.onStatus,
  });
  final bool personal, public;
  final HeatmapFilter filter;
  final int palette, revision;
  final double opacity, width;
  final List<SavedRoute>? rides;
  final ValueChanged<String>? onStatus;
  @override
  State<HeatmapPathLayer> createState() => _HeatmapPathLayerState();
}

class _HeatmapPathLayerState extends State<HeatmapPathLayer> {
  List<HeatEdge> _edges = [];
  List<HeatCell> _cells = [];
  Timer? _timer;
  String? _boundsKey;
  int _ownGeneration = 0, _publicGeneration = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant HeatmapPathLayer old) {
    super.didUpdateWidget(old);
    if (old.personal != widget.personal ||
        old.public != widget.public ||
        old.filter != widget.filter ||
        old.revision != widget.revision ||
        old.rides != widget.rides) {
      _timer?.cancel();
      _boundsKey = null;
      _publicGeneration++;
      _cells = [];
      _load();
    }
  }

  void _status(String value) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onStatus?.call(value);
    });
  }

  Future<void> _load() async {
    final generation = ++_ownGeneration, owner = UserScope.currentUserId();
    if (!widget.personal) {
      if (mounted) setState(() => _edges = []);
      return;
    }
    try {
      var rides = widget.rides;
      if (rides == null) {
        final repo = WorkoutHistoryRepository();
        await repo.load();
        rides = repo.workoutHistory;
      }
      final selected = rides.where(widget.filter.matches).toList();
      final edges = await compute(HeatmapGeometry.build, selected);
      if (!mounted ||
          generation != _ownGeneration ||
          owner != UserScope.currentUserId())
        return;
      setState(() => _edges = edges);
      _status(
        edges.isEmpty
            ? 'Нет GPS-треков по выбранным фильтрам'
            : '${selected.length} тренировок · ярче — чаще',
      );
    } catch (_) {
      if (mounted && generation == _ownGeneration) {
        setState(() => _edges = []);
        _status('Не удалось прочитать локальную историю');
      }
    }
  }

  void _public(MapCamera camera) {
    final b = camera.visibleBounds;
    final key =
        '${b.south.toStringAsFixed(3)}:${b.west.toStringAsFixed(3)}:${b.north.toStringAsFixed(3)}:${b.east.toStringAsFixed(3)}';
    if (_boundsKey == key) return;
    _boundsKey = key;
    _timer?.cancel();
    final generation = ++_publicGeneration, owner = UserScope.currentUserId();
    _timer = Timer(const Duration(milliseconds: 600), () async {
      if (b.north - b.south > 5 || b.east - b.west > 5) {
        if (mounted) {
          setState(() => _cells = []);
          _status('Приблизьте карту для публичного слоя');
        }
        return;
      }
      try {
        final cells = await TrainingHeatmap.filteredPublicCells(
          b.south,
          b.west,
          b.north,
          b.east,
          widget.filter,
        );
        if (!mounted ||
            generation != _publicGeneration ||
            owner != UserScope.currentUserId())
          return;
        setState(() => _cells = cells);
        _status(
          cells.isEmpty
              ? 'Нет публичных участков с 3 участниками по этим фильтрам'
              : 'Публичный слой · данные старше суток',
        );
      } catch (_) {
        if (mounted && generation == _publicGeneration) {
          setState(() => _cells = []);
          _boundsKey = null;
          _status('Публичная карта недоступна. Личная карта работает из кэша.');
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ownGeneration++;
    _publicGeneration++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    if (widget.public) _public(camera);
    final palette =
        heatPalettes[widget.palette.clamp(0, heatPalettes.length - 1)];
    final peak = math.max(
      _edges.fold(1, (int n, e) => math.max(n, e.count)),
      _cells.fold(1, (int n, c) => math.max(n, c.intensity)),
    );
    Color color(int count) {
      final t = peak == 1 ? .45 : math.log(1 + count) / math.log(1 + peak);
      final p = (t * (palette.length - 1)).clamp(0.0, palette.length - 1.0);
      return Color.lerp(palette[p.floor()], palette[p.ceil()], p - p.floor())!;
    }

    final bounds = camera.visibleBounds;
    final visible = _edges
        .where(
          (e) =>
              bounds.contains(e.a) ||
              bounds.contains(e.b) ||
              bounds.isOverlapping(LatLngBounds(e.a, e.b)),
        )
        .toList();
    return IgnorePointer(
      child: Stack(
        children: [
          if (widget.public)
            CircleLayer(
              circles: [
                for (final cell in _cells)
                  for (final scale in [1.5, 1.0, .55])
                    CircleMarker(
                      point: cell.point,
                      radius: 270 * scale,
                      useRadiusInMeter: true,
                      color: color(cell.intensity).withValues(
                        alpha: widget.opacity * (scale == .55 ? .4 : .15),
                      ),
                      borderStrokeWidth: 0,
                    ),
              ],
            ),
          if (widget.personal)
            for (final scale in [2.8, 1.5, .65])
              PolylineLayer(
                polylines: [
                  for (final edge in visible)
                    Polyline(
                      points: [edge.a, edge.b],
                      strokeWidth: widget.width * scale,
                      color: color(edge.count).withValues(
                        alpha:
                            widget.opacity *
                            (scale == 2.8
                                ? .12
                                : scale == 1.5
                                ? .38
                                : .95),
                      ),
                    ),
                ],
              ),
        ],
      ),
    );
  }
}
