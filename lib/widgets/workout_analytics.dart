import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/saved_route.dart';
import '../models/workout_details.dart';
import '../services/cycling_power.dart';
import '../models/bike_setup.dart';
import 'brake_workshop.dart';

class WorkoutAnalytics extends StatelessWidget {
  const WorkoutAnalytics({super.key, required this.route});
  final SavedRoute route;
  Widget _equipmentCard(BuildContext context, Map<String, dynamic> model) {
    final setup = BikeSetup.fromJson(model['setup']);
    final names =
        (model['component_names'] is List
                ? model['component_names'] as List
                : const [])
            .whereType<String>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Велосипед и расчёт энергии',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              model['vehicle_title'] is String
                  ? model['vehicle_title'] as String
                  : 'Велозаезд без привязанного велосипеда',
            ),
            Text(
              'Масса человека: ${model['rider_kg']} кг · велосипед: ${model['bike_kg'] ?? '—'} кг · багаж: ${setup.cargoKg} кг',
            ),
            Text(
              '${BikeSetup.postures[setup.posture]} · ${BikeSetup.tyreTypes[setup.tyres]}',
            ),
            if (model['is_ebike'] == true)
              Text('Мотор: ${BikeSetup.assistModes[setup.assistance]}'),
            if (names.isNotEmpty) Text('Детали на старте: ${names.join(', ')}'),
            const SizedBox(height: 8),
            const Text(
              'Калории — приблизительный общий расход по массе человека, скорости и помощи мотора (Compendium 2024). При пропусках GPS используется средний темп выбранной активности. Посадка, покрышки и багаж меняют оценку мощности. Настройки сохранены на момент старта.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = route.workoutDetails;
    final duration = Duration(
      seconds: route.durationSeconds ?? (route.durationMin * 60).round(),
    );
    final goal = data.goal;
    final foot = route.activityType.isFoot;
    final colors = Theme.of(context).colorScheme;
    final power = PowerSummary.of(data);
    final reliable = data.samples.where((s) => s.speedKmh != null).toList();
    final speedSeconds = <int>[0, 0, 0, 0];
    for (var i = 1; i < data.samples.length; i++) {
      final a = data.samples[i - 1], b = data.samples[i];
      final seconds = b.activeSeconds - a.activeSeconds;
      if (a.speedKmh == null ||
          b.speedKmh == null ||
          seconds <= 0 ||
          seconds > 15) {
        continue;
      }
      final speed = (a.speedKmh! + b.speedKmh!) / 2;
      speedSeconds[speed < 10
              ? 0
              : speed < 20
              ? 1
              : speed < 30
              ? 2
              : 3] +=
          seconds;
    }
    final measuredSeconds = speedSeconds.reduce((a, b) => a + b);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (data.walkingSteps case final walking?)
            Card(
              child: ListTile(
                leading: const Icon(Icons.directions_walk),
                title: Text('${walking.count} шагов'),
                subtitle: Text(
                  '≈ ${walking.distanceKm.toStringAsFixed(2)} км по шагам · ${duration.inSeconds > 0 ? (walking.count / (duration.inSeconds / 60)).round() : 0} шаг/мин\nРасстояние по шагам приблизительное; GPS-трек сохранён отдельно.',
                ),
              ),
            ),
          if (data.intervalPlan != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Интервальная тренировка',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${data.intervalPlan!.repeats} повторов · работа ${workoutDurationLabel(Duration(seconds: data.intervalPlan!.work))} / восстановление ${workoutDurationLabel(Duration(seconds: data.intervalPlan!.recovery))}',
                    ),
                    Text(
                      duration.inSeconds >= data.intervalPlan!.totalSeconds
                          ? 'Все этапы пройдены по времени'
                          : 'Пройдено по времени: ${(duration.inSeconds / data.intervalPlan!.totalSeconds * 100).clamp(0, 100).round()}%',
                    ),
                    const Text(
                      'План учитывает время движения, интенсивность не измеряется.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          if (data.autoLaps.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Отсечки по ${data.autoLapMeters ~/ 1000} км',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final lap in data.autoLaps)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 32,
                              child: Text(
                                '${lap.number}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                '${(lap.distanceMeters / 1000).toStringAsFixed(1)} км',
                              ),
                            ),
                            Expanded(
                              child: Text(
                                workoutDurationLabel(
                                  Duration(seconds: lap.activeSeconds),
                                ),
                              ),
                            ),
                            Text(
                              foot
                                  ? workoutPace(
                                      lap.distanceMeters,
                                      Duration(seconds: lap.activeSeconds),
                                    )
                                  : '${lap.speedKmh.toStringAsFixed(1)} км/ч',
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 4),
                    const Text(
                      'По времени движения. Последний неполный участок не входит в таблицу.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          if (data.energyModel != null)
            _equipmentCard(context, data.energyModel!),
          if (data.brakeLoad case final load?) BrakeLoadCard(load: load),
          if (data.powerModel != null && power.coveredSeconds > 0)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Расчётная мощность',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      'В среднем ≈ ${power.averageWatts!.round()} Вт · ${(power.energyJoules / 1000).round()} кДж по модели',
                    ),
                    for (final seconds in [60, 300, 1200])
                      if (power.bestAverage(seconds) != null)
                        Text(
                          'Лучшие ${seconds ~/ 60} мин: ≈ ${power.bestAverage(seconds)!.round()} Вт',
                        ),
                    Text(
                      'Охват: ${workoutDurationLabel(Duration(seconds: power.coveredSeconds))} из ${workoutDurationLabel(duration)} движения. Масса: ${data.powerModel!['rider_kg']} + ${data.powerModel!['bike_kg']} кг, багаж ${data.powerModel!['cargo_kg'] ?? 0} кг.${data.powerModel!['bike_mass_assumed'] == true ? ' Вес велосипеда принят 15 кг — уточните в гараже.' : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'GPS-оценка, не измеритель мощности. Уклон учитывается при достаточных данных, иначе принято 0%. Ветер, разгон и педалирование неизвестны. Возможна большая погрешность, особенно накатом. Старым заездам ватты не назначаются.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          if (!foot && measuredSeconds > 0)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Распределение скорости',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    for (var i = 0; i < 4; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${['До 10', '10–20', '20–30', 'От 30'][i]} км/ч · ${workoutDurationLabel(Duration(seconds: speedSeconds[i]))} · ${(speedSeconds[i] / measuredSeconds * 100).round()}%',
                            ),
                            const SizedBox(height: 4),
                            LinearProgressIndicator(
                              value: speedSeconds[i] / measuredSeconds,
                            ),
                          ],
                        ),
                      ),
                    Text(
                      'По записанным GPS-данным; паузы и пропуски не учитываются.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          if (data.elapsedSeconds > 0 || foot)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 24,
                  runSpacing: 10,
                  children: [
                    if (data.elapsedSeconds > 0)
                      Text(
                        'Всего: ${workoutDurationLabel(Duration(seconds: data.elapsedSeconds))}',
                      ),
                    if (data.elapsedSeconds > 0)
                      Text(
                        'Паузы: ${workoutDurationLabel(Duration(seconds: math.max(0, data.elapsedSeconds - duration.inSeconds)))}',
                      ),
                    if (foot)
                      Text(
                        'Средний темп: ${workoutPace(route.distanceKm * 1000, duration)}',
                      ),
                  ],
                ),
              ),
            ),
          if (goal != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Цель ${goal.label}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: goal.progress(
                        route.distanceKm * 1000,
                        duration,
                        calories: route.calories,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      goal.progress(
                                route.distanceKm * 1000,
                                duration,
                                calories: route.calories,
                              ) >=
                              1
                          ? 'Выполнена — отличная работа!'
                          : 'Выполнено ${(goal.progress(route.distanceKm * 1000, duration, calories: route.calories) * 100).round()}%',
                    ),
                  ],
                ),
              ),
            ),
          if (reliable.length >= 2)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Скорость по ходу тренировки',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 10),
                    Semantics(
                      label:
                          'График скорости. Максимум ${data.maxSpeedKmh.toStringAsFixed(1)} километра в час.',
                      child: SizedBox(
                        height: 140,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: _SpeedPainter(
                            data.samples,
                            colors.primary,
                            colors.outlineVariant,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Старт'),
                        Text(workoutDurationLabel(duration)),
                      ],
                    ),
                    Text(
                      'км/ч · по активному времени${data.samples.any((s) => s.speedKmh == null) ? ' · разрывы: нет точного GPS' : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          if (data.laps.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Круги · ${data.laps.length}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final lap in data.laps)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 30,
                              child: Text(
                                '${lap.number}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                '${(lap.distanceMeters / 1000).toStringAsFixed(2)} км',
                              ),
                            ),
                            Expanded(
                              child: Text(
                                workoutDurationLabel(
                                  Duration(seconds: lap.activeSeconds),
                                ),
                              ),
                            ),
                            Text(
                              foot
                                  ? workoutPace(
                                      lap.distanceMeters,
                                      Duration(seconds: lap.activeSeconds),
                                    )
                                  : '${lap.speedKmh.toStringAsFixed(1)} км/ч',
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (data.notes.isNotEmpty || data.effort != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (data.effort != null)
                      Text(
                        'Нагрузка по ощущениям: ${data.effort}/10',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    if (data.notes.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SelectableText(data.notes),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SpeedPainter extends CustomPainter {
  _SpeedPainter(this.samples, this.color, this.grid);
  final List<WorkoutSample> samples;
  final Color color;
  final Color grid;
  @override
  void paint(Canvas canvas, Size size) {
    final maximum = samples.fold<double>(
      1,
      (m, s) => math.max(m, s.speedKmh ?? 0),
    );
    final end = samples.fold<int>(1, (m, s) => math.max(m, s.activeSeconds));
    final axis = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var n = 0; n <= 3; n++) {
      final y = size.height * n / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), axis);
    }
    final line = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    var path = Path();
    var started = false;
    for (final sample in samples) {
      if (sample.speedKmh == null) {
        canvas.drawPath(path, line);
        path = Path();
        started = false;
        continue;
      }
      final point = Offset(
        sample.activeSeconds / end * size.width,
        size.height - sample.speedKmh! / maximum * (size.height - 8),
      );
      if (started) {
        path.lineTo(point.dx, point.dy);
      } else {
        path.moveTo(point.dx, point.dy);
        started = true;
      }
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(_SpeedPainter old) =>
      old.samples != samples || old.color != color || old.grid != grid;
}
