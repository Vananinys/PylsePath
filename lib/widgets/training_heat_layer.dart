import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../data/workout_history_repository.dart';
import '../services/training_heatmap.dart';

/// 0 off, 1 personal, 2 anonymous public aggregation.
class TrainingHeatLayer extends StatefulWidget {
  const TrainingHeatLayer({
    super.key,
    required this.mode,
    this.days = 0,
    this.onStatus,
  });
  final int mode, days;
  final ValueChanged<String>? onStatus;
  @override
  State<TrainingHeatLayer> createState() => _TrainingHeatLayerState();
}

class _TrainingHeatLayerState extends State<TrainingHeatLayer> {
  List<HeatCell> _cells = [];
  Timer? _timer;
  String? _boundsKey;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    if (widget.mode == 1) _loadOwn();
  }

  @override
  void didUpdateWidget(covariant TrainingHeatLayer old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode || old.days != widget.days) {
      _timer?.cancel();
      _generation++;
      _boundsKey = null;
      _cells = [];
      if (widget.mode == 1) _loadOwn();
    }
  }

  Future<void> _loadOwn() async {
    final generation = ++_generation;
    final repo = WorkoutHistoryRepository();
    try {
      await repo.load();
      final cutoff = DateTime.now().subtract(Duration(days: widget.days));
      final rides = repo.workoutHistory
          .where((r) => widget.days == 0 || !r.dateTime.isBefore(cutoff))
          .toList();
      final cells = await compute(TrainingHeatmap.personal, rides);
      if (mounted && generation == _generation) {
        setState(() => _cells = cells);
        widget.onStatus?.call(
          cells.isEmpty
              ? 'Нет тренировок с GPS за выбранный период'
              : '${rides.length} тренировок · ярче — чаще',
        );
      }
    } catch (_) {
      if (mounted && generation == _generation)
        widget.onStatus?.call('Не удалось загрузить историю');
    }
  }

  void _schedulePublic(LatLngBounds bounds) {
    final key =
        '${bounds.south.toStringAsFixed(3)}:${bounds.west.toStringAsFixed(3)}:${bounds.north.toStringAsFixed(3)}:${bounds.east.toStringAsFixed(3)}';
    if (key == _boundsKey) return;
    _boundsKey = key;
    _timer?.cancel();
    final generation = ++_generation;
    _timer = Timer(const Duration(milliseconds: 700), () async {
      if (bounds.north - bounds.south > 5 || bounds.east - bounds.west > 5) {
        if (mounted) {
          setState(() => _cells = []);
          widget.onStatus?.call('Приблизьте карту для просмотра тепла');
        }
        return;
      }
      try {
        final cells = await TrainingHeatmap.publicCells(
          bounds.south,
          bounds.west,
          bounds.north,
          bounds.east,
        );
        if (mounted && generation == _generation) {
          setState(() => _cells = cells);
          widget.onStatus?.call(
            cells.isEmpty
                ? 'Пока нет участков с 3 участниками в этой области'
                : 'Популярные участки · данные старше суток',
          );
        }
      } catch (_) {
        if (mounted && generation == _generation) {
          setState(() => _cells = []);
          widget.onStatus?.call(
            'Не удалось загрузить публичную карту. Повторите выбор слоя.',
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == 0) return const SizedBox.shrink();
    final bounds = MapCamera.of(context).visibleBounds;
    if (widget.mode == 2) _schedulePublic(bounds);
    final visible = _cells.where((c) => bounds.contains(c.point)).take(3000);
    return IgnorePointer(
      child: CircleLayer(
        circles: [
          for (final scale in [1.6, 1.1, 0.65])
            for (final cell in visible)
              CircleMarker(
                point: cell.point,
                radius: (widget.mode == 1 ? 75.0 : 260.0) * scale,
                useRadiusInMeter: true,
                color:
                    Color.lerp(
                      Colors.amber,
                      Colors.deepOrange,
                      TrainingHeatmap.strength(cell.intensity),
                    )!.withValues(
                      alpha:
                          TrainingHeatmap.strength(cell.intensity) *
                          (scale == 0.65 ? 0.45 : 0.17),
                    ),
                borderStrokeWidth: 0,
              ),
        ],
      ),
    );
  }
}
