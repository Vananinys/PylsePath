import 'package:flutter/material.dart';

import '../widgets/interval_training.dart';
import '../widgets/workout_steps_panel.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../controllers/map_navigation_controller.dart';
import '../models/workout_details.dart';
import '../models/gps_signal.dart';
import '../widgets/ride_navigation_controls.dart';

class RideDashboardScreen extends StatefulWidget {
  const RideDashboardScreen({
    super.key,
    required this.controller,
    required this.onFinish,
  });
  final MapNavigationController controller;
  final VoidCallback onFinish;
  @override
  State<RideDashboardScreen> createState() => _RideDashboardScreenState();
}

class _RideDashboardScreenState extends State<RideDashboardScreen> {
  bool _locked = false;
  String _left = 'average', _right = 'climb';
  static const _labels = {
    'average': 'Средняя скорость',
    'max': 'Максимальная скорость',
    'climb': 'Набор высоты',
    'calories': 'Калории · оценка',
    'remaining': 'Осталось по маршруту',
    'pace': 'Средний темп',
  };
  late final Listenable _changes = Listenable.merge([
    widget.controller,
    widget.controller.workoutTick,
    widget.controller.gpsSignal,
  ]);
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      final left = prefs.getString('ride_dashboard_left'),
          right = prefs.getString('ride_dashboard_right');
      if (_labels.containsKey(left)) _left = left!;
      if (_labels.containsKey(right)) _right = right!;
    });
  }

  Future<void> _choose(bool left, String metric) async {
    setState(() {
      if (left) {
        _left = metric;
      } else {
        _right = metric;
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      left ? 'ride_dashboard_left' : 'ride_dashboard_right',
      metric,
    );
  }

  String _value(String metric) {
    final c = widget.controller;
    return switch (metric) {
      'average' => '${c.averageSpeedKmh.toStringAsFixed(1)} км/ч',
      'max' => '${c.maxWorkoutSpeedKmh.toStringAsFixed(1)} км/ч',
      'climb' => '${c.workoutElevationGain.round()} м',
      'calories' => '${c.workoutCalories.round()} ккал',
      'pace' => workoutPace(c.totalDistanceMeters, c.activeWorkoutDuration),
      'remaining' =>
        c.isNavigating
            ? '${(c.remainingRouteMeters / 1000).toStringAsFixed(1)} км'
            : '—',
      _ => '—',
    };
  }

  Widget _metric(String label, String value, {bool large = false}) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          FittedBox(
            child: Text(
              value,
              style: TextStyle(
                fontSize: large ? 36 : 26,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Text(label, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
  Widget _slot(bool left) {
    final metric = left ? _left : _right;
    return PopupMenuButton<String>(
      enabled: !_locked,
      tooltip: 'Выбрать показатель',
      initialValue: metric,
      onSelected: (value) => _choose(left, value),
      itemBuilder: (_) => _labels.entries
          .map((e) => PopupMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      child: _metric(
        '${_labels[metric]}${_locked ? '' : ' ▾'}',
        _value(metric),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _changes,
    builder: (context, _) {
      final c = widget.controller;
      final active = c.isWorkoutActive || c.isWorkoutPaused;
      return PopScope(
        canPop: !_locked,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('В поездке'),
            automaticallyImplyLeading: !_locked,
            actions: [
              IconButton(
                tooltip: _locked ? 'Разблокировать' : 'Заблокировать кнопки',
                onPressed: () => setState(() => _locked = !_locked),
                icon: Icon(_locked ? Icons.lock : Icons.lock_open),
              ),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!active)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Тренировка завершена. Вернитесь к карте.'),
                      ),
                    ),
                  RideNavigationBanner(controller: c),
                  if (c.intervalPlan != null)
                    IntervalProgressCard(
                      plan: c.intervalPlan!,
                      activeSeconds: c.activeWorkoutDuration.inSeconds,
                      paused: c.isWorkoutPaused,
                    ),
                  Text(
                    c.isWorkoutPaused ? 'ПАУЗА' : c.workoutActivity.label,
                    textAlign: TextAlign.center,
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      c.gpsSignal.value.quality != GpsQuality.good
                          ? '—'
                          : (c.isWorkoutPaused ? 0.0 : c.instantSpeedKmh)
                                .toStringAsFixed(1),
                      style: const TextStyle(
                        fontSize: 100,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const Text('км/ч', textAlign: TextAlign.center),
                  _metric(
                    'Средний темп',
                    workoutPace(c.totalDistanceMeters, c.activeWorkoutDuration),
                  ),
                  if (c.workoutActivity.isFoot)
                    WorkoutStepsPanel(controller: c),
                  Row(
                    children: [
                      Expanded(
                        child: _metric(
                          'Километры',
                          (c.totalDistanceMeters / 1000).toStringAsFixed(2),
                          large: true,
                        ),
                      ),
                      Expanded(
                        child: _metric(
                          'Время движения',
                          workoutTime(c.activeWorkoutDuration),
                          large: true,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(child: _slot(true)),
                      Expanded(child: _slot(false)),
                    ],
                  ),
                  Text(
                    'GPS: ${switch (c.gpsSignal.value.quality) {
                      GpsQuality.good => 'точный',
                      GpsQuality.weak => 'неточный',
                      GpsQuality.searching => 'поиск',
                      GpsQuality.lost => 'сигнал потерян',
                    }} · ±${c.gpsSignal.value.accuracy?.round().toString() ?? '—'} м',
                    textAlign: TextAlign.center,
                  ),
                  ReturnToStartButton(
                    controller: c,
                    enabled: !_locked && active,
                  ),
                  if (c.isOffRoute && c.followsSavedTrack)
                    OutlinedButton(
                      onPressed: _locked || c.isLoadingRoute
                          ? null
                          : () async {
                              try {
                                await c.buildRoute();
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Не удалось перестроить: сохранённый трек остаётся на карте.',
                                      ),
                                    ),
                                  );
                                }
                              }
                            },
                      child: const Text(
                        'Перестроить по дорогам · нужен интернет',
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: _locked || !active || c.isSavingWorkout
                              ? null
                              : () {
                                  if (c.isWorkoutPaused) {
                                    c.resumeWorkout();
                                  } else {
                                    c.pauseWorkout();
                                  }
                                },
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Text(
                              c.isWorkoutPaused ? 'Продолжить' : 'Пауза',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _locked || !active || c.isSavingWorkout
                              ? null
                              : widget.onFinish,
                          child: const Padding(
                            padding: EdgeInsets.all(14),
                            child: Text('Финиш'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
