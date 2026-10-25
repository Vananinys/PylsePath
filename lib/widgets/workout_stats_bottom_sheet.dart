import 'package:flutter/material.dart';

import '../controllers/map_navigation_controller.dart';
import '../data/saved_routes_repository.dart';
import '../models/gps_signal.dart';
import '../models/workout_details.dart';
import '../screens/ride_dashboard_screen.dart';
import 'ride_navigation_controls.dart';
import 'interval_training.dart';
import 'workout_steps_panel.dart';

class WorkoutStatsBottomSheet extends StatelessWidget {
  const WorkoutStatsBottomSheet({
    super.key,
    required this.controller,
    required this.savedRoutesRepo,
    required this.onPauseResumePressed,
    required this.onFinishPressed,
    this.isPaused = false,
    this.isAutoPaused = false,
    this.isLocked = false,
    this.onSharingChanged,
    this.gearAdvisor,
    this.expanded = false,
  });
  final MapNavigationController controller;
  final SavedRoutesRepository savedRoutesRepo;
  final VoidCallback onPauseResumePressed;
  final VoidCallback onFinishPressed;
  final ValueChanged<bool>? onSharingChanged;
  final bool isPaused;
  final bool isAutoPaused;
  final bool isLocked;
  final Widget? gearAdvisor;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    if (expanded) return _buildExpandedContent(context);
    final c = controller;
    if (!c.isWorkoutActive && !c.isWorkoutPaused)
      return const SizedBox.shrink();
    final disabled = isLocked || c.isSavingWorkout;
    final colors = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      color: colors.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .42,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: disabled
                      ? null
                      : () => expanded
                            ? Navigator.pop(context)
                            : _expand(context),
                  onVerticalDragEnd: disabled
                      ? null
                      : (details) {
                          if ((details.primaryVelocity ?? 0) < -80)
                            _expand(context);
                        },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          c.workoutActivity.icon,
                          size: 20,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isAutoPaused
                                ? 'Автопауза'
                                : isPaused
                                ? 'Тренировка на паузе'
                                : '${c.workoutActivity.label} · запись',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        TextButton(
                          onPressed: disabled ? null : () => _expand(context),
                          child: const Text('Подробнее'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _metric(
                        context,
                        c.gpsSignal.value.quality != GpsQuality.good
                            ? '—'
                            : (isPaused ? 0.0 : c.instantSpeedKmh)
                                  .toStringAsFixed(1)
                                  .replaceAll('.', ','),
                        'км/ч',
                        large: true,
                      ),
                    ),
                    Expanded(
                      child: _metric(
                        context,
                        (c.totalDistanceMeters / 1000)
                            .toStringAsFixed(2)
                            .replaceAll('.', ','),
                        'км',
                        large: true,
                      ),
                    ),
                    Expanded(
                      child: _metric(
                        context,
                        workoutTime(c.activeWorkoutDuration),
                        'время',
                        large: true,
                      ),
                    ),
                  ],
                ),
                if (c.workoutActivity.isFoot)
                  ListenableBuilder(
                    listenable: c.stepTracker,
                    builder: (_, __) => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('${c.stepTracker.count} шагов'),
                    ),
                  ),
                if (c.workoutGoal != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      children: [
                        Text(
                          '${c.workoutGoal!.label} · ${(c.workoutGoalProgress * 100).round()}%',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        LinearProgressIndicator(value: c.workoutGoalProgress),
                      ],
                    ),
                  ),
                if (gearAdvisor != null) gearAdvisor!,
                if (c.checkpointError != null)
                  Text(
                    c.checkpointError!,
                    style: TextStyle(color: colors.error),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed:
                            disabled ||
                                isPaused ||
                                c.activeWorkoutDuration.inSeconds < 1
                            ? null
                            : c.markWorkoutLap,
                        child: const Text('Круг'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: disabled ? null : onPauseResumePressed,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(isPaused ? 'Продолжить' : 'Пауза'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: disabled ? null : onFinishPressed,
                        child: const FittedBox(child: Text('Финиш')),
                      ),
                    ),
                  ],
                ),
                if (isLocked) const Text('Экран заблокирован'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedContent(BuildContext context) {
    final c = controller;
    if (!c.isWorkoutActive && !c.isWorkoutPaused) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    final duration = c.activeWorkoutDuration;
    final goal = c.workoutGoal;
    final progress = c.workoutGoalProgress;
    final disabled = isLocked || c.isSavingWorkout;
    final lastLap = c.workoutLaps.lastOrNull;
    final autoLap = c.automaticLaps.lastOrNull;
    return Material(
      elevation: 8,
      color: colors.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .88,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  button: true,
                  label: expanded
                      ? 'Свернуть тренировку'
                      : 'Развернуть тренировку',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: disabled
                        ? null
                        : () => expanded
                              ? Navigator.pop(context)
                              : _expand(context),
                    onVerticalDragEnd: disabled
                        ? null
                        : (details) {
                            if (expanded && (details.primaryVelocity ?? 0) > 80)
                              Navigator.pop(context);
                            if (!expanded &&
                                (details.primaryVelocity ?? 0) < -80)
                              _expand(context);
                          },
                    child: SizedBox(
                      height: 32,
                      child: Center(
                        child: Container(
                          width: 44,
                          height: 5,
                          decoration: BoxDecoration(
                            color: colors.outlineVariant,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (c.intervalPlan != null)
                  IntervalProgressCard(
                    plan: c.intervalPlan!,
                    activeSeconds: duration.inSeconds,
                    paused: isPaused,
                  ),
                if (c.autoLapMeters > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      autoLap == null
                          ? 'Отсечки по ${c.autoLapMeters ~/ 1000} км · первая впереди'
                          : 'Отсечка ${autoLap.number} · ${workoutTime(Duration(seconds: autoLap.activeSeconds))} · ${autoLap.speedKmh.toStringAsFixed(1)} км/ч',
                      style: TextStyle(
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                Row(
                  children: [
                    Icon(c.workoutActivity.icon, color: colors.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isAutoPaused
                            ? 'Автопауза · ждём движения'
                            : isPaused
                            ? 'Тренировка на паузе'
                            : '${c.workoutActivity.label} · запись',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (onSharingChanged != null)
                      IconButton(
                        tooltip: c.shareLivePosition
                            ? 'Позиция доступна друзьям. Выключить'
                            : 'Позиция скрыта. Включить',
                        onPressed: disabled
                            ? null
                            : () => onSharingChanged!(!c.shareLivePosition),
                        icon: Icon(
                          c.shareLivePosition
                              ? Icons.location_on
                              : Icons.location_off,
                          color: c.shareLivePosition
                              ? colors.primary
                              : colors.outline,
                        ),
                      ),
                    IconButton(
                      tooltip: 'Крупный экран поездки',
                      onPressed: disabled
                          ? null
                          : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => RideDashboardScreen(
                                  controller: c,
                                  onFinish: onFinishPressed,
                                ),
                              ),
                            ),
                      icon: const Icon(Icons.fullscreen),
                    ),
                  ],
                ),
                ReturnToStartButton(controller: c, enabled: !disabled),
                if (gearAdvisor != null) gearAdvisor!,
                ValueListenableBuilder<GpsSignal>(
                  valueListenable: c.gpsSignal,
                  builder: (context, gps, _) => gps.quality == GpsQuality.good
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            gps.quality == GpsQuality.weak
                                ? 'Неточный GPS: часть точек не попадёт в трек'
                                : 'Нет свежего GPS: время идёт, координаты не выдумываются',
                            style: TextStyle(color: colors.error, fontSize: 12),
                          ),
                        ),
                ),
                if (c.checkpointError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      c.checkpointError!,
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: _metric(
                        context,
                        c.gpsSignal.value.quality != GpsQuality.good
                            ? '—'
                            : (isPaused ? 0.0 : c.instantSpeedKmh)
                                  .toStringAsFixed(1),
                        'км/ч',
                        large: true,
                      ),
                    ),
                    Expanded(
                      child: _metric(
                        context,
                        (c.totalDistanceMeters / 1000).toStringAsFixed(2),
                        'километры',
                        large: true,
                      ),
                    ),
                    Expanded(
                      child: _metric(
                        context,
                        workoutTime(duration),
                        'время движения',
                        large: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _metric(
                        context,
                        '${c.averageSpeedKmh.toStringAsFixed(1)} км/ч',
                        'средняя',
                      ),
                    ),
                    Expanded(
                      child: _metric(
                        context,
                        '${c.maxWorkoutSpeedKmh.toStringAsFixed(1)} км/ч',
                        'максимальная',
                      ),
                    ),
                    Expanded(
                      child: _metric(
                        context,
                        '${c.workoutElevationGain.round()} м',
                        'набор высоты',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (c.workoutActivity.isFoot) WorkoutStepsPanel(controller: c),
                if (c.hasPowerEstimate)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.bolt, color: Colors.deepOrange),
                    title: Text(
                      c.estimatedPowerWatts == null
                          ? 'Мощность: нет оценки'
                          : '≈ ${c.estimatedPowerWatts!.round()} Вт',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      c.powerGradePercent == null
                          ? 'Расчёт · уклон неизвестен, принято 0%'
                          : 'Расчёт · уклон GPS ${c.powerGradePercent!.toStringAsFixed(1)}%',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.info_outline),
                      tooltip: 'Как рассчитаны ватты',
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Расчётная мощность'),
                          content: Text(
                            'Масса: ${c.powerModel?['rider_kg']} кг + велосипед ${c.powerModel?['bike_kg']} кг + багаж ${c.powerModel?['cargo_kg'] ?? 0} кг.${c.powerModel?['bike_mass_assumed'] == true ? ' Вес велосипеда принят 15 кг по умолчанию.' : ''}\n\nМодель сопротивления качению, воздуха и подъёма. Посадку и тип покрышек можно выбрать в гараже. Ветер, разгон и вращение педалей не измеряются. Без надёжного уклона предполагается ровная дорога. На спуске или при движении накатом оценка может сильно отличаться от усилия ног. Для электровелосипеда оценка отключена.\n\nПроверьте свой вес в профиле и вес велосипеда в гараже.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Понятно'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (goal != null) ...[
                  Row(
                    children: [
                      Icon(
                        progress >= 1
                            ? Icons.check_circle
                            : Icons.flag_outlined,
                        color: colors.primary,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          progress >= 1
                              ? 'Цель ${goal.label} выполнена!'
                              : 'Цель ${goal.label} · ${(progress * 100).round()}%',
                        ),
                      ),
                      Text(
                        '${c.workoutCalories.round()} ккал · оценка',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: progress,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  const SizedBox(height: 8),
                ] else
                  Text(
                    '${c.workoutCalories.round()} ккал · приблизительная оценка',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (lastLap != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Круг ${lastLap.number}: ${(lastLap.distanceMeters / 1000).toStringAsFixed(2)} км · ${workoutTime(Duration(seconds: lastLap.activeSeconds))}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed:
                            disabled || isPaused || duration.inSeconds < 1
                            ? null
                            : () {
                                c.markWorkoutLap();
                              },
                        child: const FittedBox(
                          child: Row(
                            children: [
                              Icon(Icons.flag_outlined, size: 18),
                              SizedBox(width: 4),
                              Text('Круг'),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: disabled ? null : onPauseResumePressed,
                        child: FittedBox(
                          child: Row(
                            children: [
                              Icon(
                                isPaused ? Icons.play_arrow : Icons.pause,
                                size: 18,
                              ),
                              const SizedBox(width: 4),
                              Text(isPaused ? 'Продолжить' : 'Пауза'),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: disabled ? null : onFinishPressed,
                        child: FittedBox(
                          child: Text(
                            c.isSavingWorkout ? 'Сохраняем…' : 'Финиш',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (isLocked)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'Экран заблокирован',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _metric(
    BuildContext context,
    String value,
    String label, {
    bool large = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: TextStyle(
              fontSize: large ? 25 : 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  void _expand(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => ListenableBuilder(
      listenable: Listenable.merge([
        controller,
        controller.workoutTick,
        controller.gpsSignal,
      ]),
      builder: (context, _) => WorkoutStatsBottomSheet(
        expanded: true,
        controller: controller,
        savedRoutesRepo: savedRoutesRepo,
        onPauseResumePressed: onPauseResumePressed,
        onFinishPressed: () {
          Navigator.pop(context);
          onFinishPressed();
        },
        onSharingChanged: onSharingChanged,
        isPaused: controller.isWorkoutPaused,
        isAutoPaused: controller.isAutoPaused,
        isLocked: isLocked,
        gearAdvisor: gearAdvisor,
      ),
    ),
  );
}
