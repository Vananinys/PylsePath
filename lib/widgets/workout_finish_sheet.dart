import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/map_navigation_controller.dart';
import '../models/workout_details.dart';
import '../config/app_variant.dart';

class WorkoutFinishRequest {
  const WorkoutFinishRequest({
    this.title = '',
    this.notes = '',
    this.effort,
    this.discard = false,
    this.endGroupParticipation = false,
  });
  final String title;
  final String notes;
  final int? effort;
  final bool discard;
  final bool endGroupParticipation;
}

class WorkoutFinishSheet extends StatefulWidget {
  const WorkoutFinishSheet({super.key, required this.controller});
  final MapNavigationController controller;
  @override
  State<WorkoutFinishSheet> createState() => _WorkoutFinishSheetState();
}

class _WorkoutFinishSheetState extends State<WorkoutFinishSheet> {
  late final _title = TextEditingController(
    text:
        '${widget.controller.workoutActivity.label} · ${DateTime.now().day}.${DateTime.now().month}',
  );
  final _notes = TextEditingController();
  int? _effort;
  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Завершение тренировки',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  '${(c.totalDistanceMeters / 1000).toStringAsFixed(2)} км  ·  ${workoutDurationLabel(c.activeWorkoutDuration)} движения',
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ),
            const SizedBox(height: 12),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Все показатели'),
              subtitle: const Text('Скорость, темп, высота и калории'),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(
                      label: Text(
                        'Средняя скорость: ${c.averageSpeedKmh.toStringAsFixed(1)} км/ч',
                      ),
                    ),
                    Chip(
                      label: Text(
                        'Максимальная: ${c.maxWorkoutSpeedKmh.toStringAsFixed(1)} км/ч',
                      ),
                    ),
                    Chip(
                      label: Text(
                        'Средний темп: ${workoutPace(c.totalDistanceMeters, c.activeWorkoutDuration)}',
                      ),
                    ),
                    Chip(
                      label: Text(
                        'Набор высоты: ${c.workoutElevationGain.round()} м',
                      ),
                    ),
                    Chip(label: Text('≈ ${c.workoutCalories.round()} ккал')),
                    if (c.workoutLaps.isNotEmpty)
                      Chip(label: Text('Кругов: ${c.workoutLaps.length}')),
                  ],
                ),
              ],
            ),
            if (c.recordedPath.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'GPS-трек пока не записан. Время активности можно сохранить.',
                ),
              ),
            if (c.workoutActivity.isFoot)
              Text(
                '${c.stepTracker.count} шагов · ≈ ${c.stepTracker.distanceKm.toStringAsFixed(2)} км по шагам',
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              maxLength: 100,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Название',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _notes,
              maxLength: 2000,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Заметка',
                hintText: 'Как прошла тренировка?',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text('Насколько тяжело было? Необязательно'),
            Wrap(
              spacing: 4,
              children: [
                for (var n = 1; n <= 10; n++)
                  ChoiceChip(
                    label: Text('$n'),
                    selected: _effort == n,
                    onSelected: (selected) =>
                        setState(() => _effort = selected ? n : null),
                  ),
              ],
            ),
            const Text(
              '1 — легко, 10 — предельно тяжело',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => Navigator.pop(
                context,
                WorkoutFinishRequest(
                  title: _title.text.trim(),
                  notes: _notes.text.trim(),
                  effort: _effort,
                ),
              ),
              icon: const Icon(Icons.check),
              label: const Text('Сохранить тренировку'),
            ),
            if (AppVariant.uiBeta && c.groupWorkoutConnected) ...[
              const Text(
                'Сохранение завершит только вашу запись. Можно остаться и посмотреть результаты остальных.',
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(
                  context,
                  WorkoutFinishRequest(
                    title: _title.text.trim(),
                    notes: _notes.text.trim(),
                    effort: _effort,
                    endGroupParticipation: true,
                  ),
                ),
                icon: const Icon(Icons.logout),
                label: const Text('Сохранить и завершить участие в заезде'),
              ),
            ],
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Продолжить тренировку'),
            ),
            TextButton(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Удалить без сохранения?'),
                    content: const Text(
                      'Трек и показатели этой тренировки будут удалены.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Отмена'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Удалить'),
                      ),
                    ],
                  ),
                );
                if (confirm == true && context.mounted) {
                  Navigator.pop(
                    context,
                    const WorkoutFinishRequest(discard: true),
                  );
                }
              },
              child: const Text(
                'Удалить без сохранения',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RideCountdown extends StatefulWidget {
  const RideCountdown({super.key});
  @override
  State<RideCountdown> createState() => _RideCountdownState();
}

class _RideCountdownState extends State<RideCountdown> {
  int _seconds = 3;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_seconds == 1) {
        _timer?.cancel();
        Navigator.pop(context, true);
      } else {
        setState(() => _seconds--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Приготовьтесь'),
    content: Semantics(
      liveRegion: true,
      child: Text(
        '$_seconds',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.displayLarge,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Отмена'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Начать сейчас'),
      ),
    ],
  );
}
