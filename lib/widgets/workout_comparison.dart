import 'package:flutter/material.dart';

import '../data/workout_history_repository.dart';
import '../models/saved_route.dart';
import '../models/workout_details.dart';
import '../services/achievements_service.dart';
import '../services/ride_pulse.dart';

class WorkoutComparison extends StatefulWidget {
  const WorkoutComparison({super.key, required this.route});
  final SavedRoute route;
  @override
  State<WorkoutComparison> createState() => _WorkoutComparisonState();
}

class _WorkoutComparisonState extends State<WorkoutComparison> {
  List<SavedRoute> _previous = [];
  String? _selected;
  final Set<String> _repeatIds = {};
  bool _loading = true, _failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final repo = WorkoutHistoryRepository();
      await repo.load();
      final current = widget.route;
      final previous =
          repo.workoutHistory
              .where(
                (r) =>
                    r.localId != current.localId &&
                    (current.remoteId == null ||
                        r.remoteId != current.remoteId) &&
                    r.activityType == current.activityType &&
                    r.dateTime.isBefore(current.dateTime) &&
                    r.distanceKm > 0 &&
                    r.durationMin > 0,
              )
              .toList()
            ..sort((a, b) => b.dateTime.compareTo(a.dateTime));
      final similar = previous
          .where(
            (r) =>
                current.distanceKm > 0 &&
                (r.distanceKm - current.distanceKm).abs() /
                        current.distanceKm <=
                    .2,
          )
          .firstOrNull;
      final repeated = previous
          .take(60)
          .where((r) => RidePulse.matchesRoute(current, r))
          .toList();
      if (mounted)
        setState(() {
          _previous = previous;
          _repeatIds.addAll(repeated.map((r) => r.localId));
          _selected = (repeated.firstOrNull ?? similar ?? previous.firstOrNull)
              ?.localId;
          _loading = false;
          _failed = false;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _failed = true;
          _loading = false;
        });
    }
  }

  String _signed(double value, {int precision = 1}) =>
      '${value > 0 ? '+' : ''}${value.toStringAsFixed(precision)}';
  @override
  Widget build(BuildContext context) {
    if (_loading)
      return const Padding(
        padding: EdgeInsets.all(16),
        child: LinearProgressIndicator(),
      );
    if (_failed)
      return TextButton(
        onPressed: _load,
        child: const Text('Повторить загрузку сравнения'),
      );
    final current = widget.route;
    final base = _previous.where((r) => r.localId == _selected).firstOrNull;
    final speed = AchievementsService.averageSpeedKmh(current);
    final bestKm = _previous.fold(
      0.0,
      (best, r) => r.distanceKm > best ? r.distanceKm : best,
    );
    final bestClimb = _previous.fold(
      0.0,
      (best, r) => r.elevationGainMeters > best ? r.elevationGainMeters : best,
    );
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Сравнение с прошлыми тренировками',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (base == null)
              const Text(
                'После следующей тренировки этого вида здесь появится сравнение.',
              )
            else ...[
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _repeatIds.contains(_selected)
                      ? '↻ Похожий трек: совпадают направление, дистанция и форма маршрута.'
                      : 'Сравнение по виду активности. Маршруты могут отличаться.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              DropdownButton<String>(
                isExpanded: true,
                value: _selected,
                items: _previous
                    .map(
                      (r) => DropdownMenuItem(
                        value: r.localId,
                        child: Text(
                          '${_repeatIds.contains(r.localId) ? '↻ ' : ''}${r.dateTime.toLocal().toString().split(' ').first} · ${r.distanceKm.toStringAsFixed(1)} км · ${r.title}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _selected = value),
              ),
              Text(
                'Дистанция: ${current.distanceKm.toStringAsFixed(1)} км · раньше ${base.distanceKm.toStringAsFixed(1)} км',
              ),
              Text(
                'Средняя скорость: ${speed.toStringAsFixed(1)} км/ч · ${_signed(speed - AchievementsService.averageSpeedKmh(base))} км/ч',
              ),
              if ((base.distanceKm - current.distanceKm).abs() <=
                  current.distanceKm * .2)
                Text(
                  'Время движения: ${workoutTime(Duration(seconds: (current.durationMin * 60).round()))} · ${_signed(current.durationMin - base.durationMin)} мин',
                ),
              if (current.workoutDetails.elapsedSeconds > 0 &&
                  base.workoutDetails.elapsedSeconds > 0)
                Text(
                  'Паузы: ${workoutTime(Duration(seconds: (current.workoutDetails.elapsedSeconds - current.durationMin * 60).clamp(0, double.infinity).round()))} · раньше ${workoutTime(Duration(seconds: (base.workoutDetails.elapsedSeconds - base.durationMin * 60).clamp(0, double.infinity).round()))}',
                ),
              if (current.elevationGainMeters > 0 &&
                  base.elevationGainMeters > 0)
                Text(
                  'Набор высоты: ${current.elevationGainMeters.round()} м · ${_signed(current.elevationGainMeters - base.elevationGainMeters, precision: 0)} м',
                ),
              const SizedBox(height: 6),
              const Text(
                'Условия, покрытие и ветер могут различаться. Скорость сама по себе не измеряет форму.',
                style: TextStyle(fontSize: 12),
              ),
            ],
            if (_previous.isNotEmpty && current.distanceKm > bestKm)
              const Text(
                '🏆 Самая длинная тренировка этого вида в сохранённой истории',
              ),
            if (_previous.isNotEmpty &&
                current.elevationGainMeters > bestClimb &&
                bestClimb > 0)
              const Text('🏔️ Новый рекорд набора высоты этого вида'),
            if (current.workoutDetails.goal != null)
              Text(
                'Цель: ${(current.workoutDetails.goal!.progress(current.distanceKm * 1000, Duration(seconds: (current.durationMin * 60).round()), calories: current.calories) * 100).round()}% · ${current.workoutDetails.goal!.label}',
              ),
          ],
        ),
      ),
    );
  }
}
