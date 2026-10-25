import 'package:flutter/material.dart';

import '../controllers/map_navigation_controller.dart';
import '../services/recording_daily_activity_service.dart';

class WorkoutStepsPanel extends StatelessWidget {
  const WorkoutStepsPanel({super.key, required this.controller});
  final MapNavigationController controller;
  @override
  Widget build(BuildContext context) {
    if (!controller.workoutActivity.isFoot) return const SizedBox.shrink();
    final steps = controller.stepTracker;
    return ListenableBuilder(
      listenable: Listenable.merge([steps, DailyActivityService.instance]),
      builder: (context, _) {
        final minutes = controller.activeWorkoutDuration.inSeconds / 60;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.directions_walk),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${steps.count} шагов',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Text(
                      minutes > 0
                          ? '${(steps.count / minutes).round()} шаг/мин'
                          : '— шаг/мин',
                    ),
                  ],
                ),
                Text(
                  '≈ ${steps.distanceKm.toStringAsFixed(2)} км по длине шага · отдельно от GPS',
                ),
                if (!DailyActivityService.instance.enabled)
                  TextButton(
                    onPressed: () async {
                      final daily = DailyActivityService.instance;
                      if (!daily.ready) await daily.initialize();
                      await daily.setEnabled(true);
                      await steps.refresh();
                    },
                    child: const Text('Включить шагомер'),
                  ),
                if (steps.notice != null)
                  Text(
                    steps.notice!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
