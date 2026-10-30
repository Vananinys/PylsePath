import 'package:flutter/material.dart';

import '../controllers/map_navigation_controller.dart';
import '../models/gps_signal.dart';
import '../models/workout_details.dart';
import 'interval_training.dart';

class RidePreparationPanel extends StatefulWidget {
  const RidePreparationPanel({
    super.key,
    required this.controller,
    required this.onSharingChanged,
    required this.onGpsRetry,
    this.showGps = true,
  });
  final MapNavigationController controller;
  final ValueChanged<bool> onSharingChanged;
  final Future<void> Function() onGpsRetry;
  final bool showGps;
  @override
  State<RidePreparationPanel> createState() => _RidePreparationPanelState();
}

class _RidePreparationPanelState extends State<RidePreparationPanel> {
  bool _checkingGps = false;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.controller,
      widget.controller.gpsSignal,
    ]),
    builder: (context, _) {
      final signal = widget.controller.gpsSignal.value;
      final c = widget.controller;
      final goal = c.workoutGoal;
      final gpsText = switch (signal.quality) {
        GpsQuality.good => 'GPS готов · ±${signal.accuracy!.ceil()} м',
        GpsQuality.weak => 'GPS неточный · трек может искажаться',
        GpsQuality.searching => 'Ищем спутники',
        GpsQuality.lost => 'GPS недоступен',
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (c.preRideVehicle?.parts.any(
                (part) => part.due(c.preRideVehicle!.totalDistance),
              ) ??
              false)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Перед выездом проверьте: ${c.preRideVehicle!.parts.where((part) => part.due(c.preRideVehicle!.totalDistance)).map((part) => part.name).join(', ')}. Журнал — в гараже.',
                ),
              ),
            ),
          if (widget.showGps)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                signal.quality == GpsQuality.good
                    ? Icons.gps_fixed
                    : Icons.gps_not_fixed,
                color: signal.quality == GpsQuality.good
                    ? Colors.green
                    : Colors.orange,
              ),
              title: Text(gpsText),
              trailing: IconButton(
                tooltip: 'Проверить GPS',
                icon: _checkingGps
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                onPressed: _checkingGps
                    ? null
                    : () async {
                        setState(() => _checkingGps = true);
                        try {
                          await widget.onGpsRetry();
                        } finally {
                          if (mounted) setState(() => _checkingGps = false);
                        }
                      },
              ),
            ),
          ExpansionTile(
            key: const PageStorageKey('training-goals'),
            tilePadding: EdgeInsets.zero,
            title: const Text('Цель и интервалы'),
            subtitle: Text(
              '${goal?.label ?? 'Свободная тренировка'} · ${c.intervalPlan == null ? 'без интервалов' : 'интервалы включены'}',
            ),
            children: [
              IntervalSetup(controller: c),
              const SizedBox(height: 12),
              const Text(
                'Цель тренировки',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text('Свободная'),
                    selected: goal == null,
                    onSelected: (_) => c.setWorkoutGoal(null),
                  ),
                  for (final km in [5, 10, 20])
                    ChoiceChip(
                      label: Text('$km км'),
                      selected:
                          goal?.kind == WorkoutGoalKind.distance &&
                          goal?.target == km * 1000,
                      onSelected: (_) => c.setWorkoutGoal(
                        WorkoutGoal(WorkoutGoalKind.distance, km * 1000),
                      ),
                    ),
                  for (final min in [30, 60])
                    ChoiceChip(
                      label: Text('$min мин'),
                      selected:
                          goal?.kind == WorkoutGoalKind.duration &&
                          goal?.target == min * 60,
                      onSelected: (_) => c.setWorkoutGoal(
                        WorkoutGoal(WorkoutGoalKind.duration, min * 60),
                      ),
                    ),
                  ActionChip(
                    label: const Text('Своя дистанция / время'),
                    avatar: const Icon(Icons.tune, size: 16),
                    onPressed: () => _chooseGoal(context, goal, c),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final kcal in [100, 200, 400])
                    ChoiceChip(
                      label: Text('$kcal ккал'),
                      selected:
                          goal?.kind == WorkoutGoalKind.calories &&
                          goal?.target == kcal,
                      onSelected: (_) => c.setWorkoutGoal(
                        WorkoutGoal(WorkoutGoalKind.calories, kcal.toDouble()),
                      ),
                    ),
                  ActionChip(
                    label: const Text('Своя цель в ккал'),
                    avatar: const Icon(
                      Icons.local_fire_department_outlined,
                      size: 16,
                    ),
                    onPressed: () => _chooseGoal(context, goal, c),
                  ),
                ],
              ),
              if (goal != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Цель: ${goal.label}. Завершение — вручную.${goal.kind == WorkoutGoalKind.calories ? ' Калории — приблизительная оценка.' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          ExpansionTile(
            key: const PageStorageKey('training-recording'),
            tilePadding: EdgeInsets.zero,
            title: const Text('Запись и отсечки'),
            subtitle: Text(
              '${c.autoLapMeters == 0 ? 'Без отсечек' : 'Отсечки ${c.autoLapMeters ~/ 1000} км'} · запись с выключенным экраном',
            ),
            children: [
              Text(
                'Начатая тренировка записывается с выключенным экраном. Пауза и финиш — вручную.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              const Text(
                'Автоматические отсечки',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                children: [
                  for (final meters in [0, 1000, 5000, 10000])
                    ChoiceChip(
                      label: Text(
                        meters == 0 ? 'Выключены' : '${meters ~/ 1000} км',
                      ),
                      selected: c.autoLapMeters == meters,
                      onSelected: (_) => c.setAutoLapMeters(meters),
                    ),
                ],
              ),
            ],
          ),
          ExpansionTile(
            key: const PageStorageKey('training-privacy'),
            tilePadding: EdgeInsets.zero,
            title: const Text('Кто видит мою позицию'),
            subtitle: Text(
              c.shareLivePosition
                  ? 'Позиция доступна друзьям'
                  : 'Позиция скрыта',
            ),
            children: [
              SwitchListTile.adaptive(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Показывать позицию друзьям'),
                subtitle: const Text('В открытом приложении и во время заезда'),
                value: c.shareLivePosition,
                onChanged: widget.onSharingChanged,
              ),
            ],
          ),
        ],
      );
    },
  );

  Future<void> _chooseGoal(
    BuildContext context,
    WorkoutGoal? goal,
    MapNavigationController controller,
  ) async {
    final value = await showDialog<WorkoutGoal>(
      context: context,
      builder: (_) => _GoalDialog(goal: goal),
    );
    if (value != null) controller.setWorkoutGoal(value);
  }
}

class _GoalDialog extends StatefulWidget {
  const _GoalDialog({this.goal});
  final WorkoutGoal? goal;
  @override
  State<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<_GoalDialog> {
  late WorkoutGoalKind _kind = widget.goal?.kind ?? WorkoutGoalKind.distance;
  late final _number = TextEditingController(
    text: widget.goal == null
        ? '10'
        : (widget.goal!.target /
                  (widget.goal!.kind == WorkoutGoalKind.distance
                      ? 1000
                      : widget.goal!.kind == WorkoutGoalKind.calories
                      ? 1
                      : 60))
              .toStringAsFixed(0),
  );
  String? _error;
  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Своя цель'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButton<WorkoutGoalKind>(
          isExpanded: true,
          value: _kind,
          items: const [
            DropdownMenuItem(
              value: WorkoutGoalKind.distance,
              child: Text('Дистанция, км'),
            ),
            DropdownMenuItem(
              value: WorkoutGoalKind.duration,
              child: Text('Время движения, мин'),
            ),
            DropdownMenuItem(
              value: WorkoutGoalKind.calories,
              child: Text('Расход энергии, ккал · оценка'),
            ),
          ],
          onChanged: (v) => setState(() {
            _kind = v!;
            _error = null;
          }),
        ),
        TextField(
          controller: _number,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: _kind == WorkoutGoalKind.distance
                ? 'От 0,1 до 500 км'
                : _kind == WorkoutGoalKind.calories
                ? 'От 10 до 10000 ккал'
                : 'От 1 до 1440 мин',
            errorText: _error,
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          final number = double.tryParse(
            _number.text.trim().replaceAll(',', '.'),
          );
          final min = _kind == WorkoutGoalKind.distance
              ? .1
              : _kind == WorkoutGoalKind.calories
              ? 10
              : 1;
          final max = _kind == WorkoutGoalKind.distance
              ? 500
              : _kind == WorkoutGoalKind.calories
              ? 10000
              : 1440;
          if (number == null ||
              !number.isFinite ||
              number < min ||
              number > max) {
            setState(() => _error = 'Введите число от $min до $max');
            return;
          }
          Navigator.pop(
            context,
            WorkoutGoal(
              _kind,
              number *
                  (_kind == WorkoutGoalKind.distance
                      ? 1000
                      : _kind == WorkoutGoalKind.calories
                      ? 1
                      : 60),
            ),
          );
        },
        child: const Text('Выбрать'),
      ),
    ],
  );
}
