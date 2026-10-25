import 'package:flutter/material.dart';

import '../controllers/map_navigation_controller.dart';

class RideNavigationBanner extends StatelessWidget {
  const RideNavigationBanner({super.key, required this.controller});
  final MapNavigationController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (!c.isNavigating || c.routePoints.isEmpty)
      return const SizedBox.shrink();
    final step = c.routeSteps.isEmpty
        ? null
        : c.routeSteps[c.currentStepIndex.clamp(0, c.routeSteps.length - 1)];
    return Card(
      color: c.isOffRoute ? Theme.of(context).colorScheme.errorContainer : null,
      child: ListTile(
        leading: Icon(
          c.isOffRoute
              ? Icons.wrong_location_outlined
              : step?.icon ?? Icons.route,
        ),
        title: Text(
          c.isOffRoute
              ? 'В стороне от маршрута · ${c.routeDeviationMeters.round()} м'
              : step?.instruction ?? 'Следуйте по маршруту',
        ),
        subtitle: Text(
          c.isOffRoute
              ? (c.followsSavedTrack
                    ? 'Трек сохранён. Вернитесь к линии или выберите перестроение.'
                    : 'Пробуем перестроить путь по дорогам.')
              : '${c.distanceToNextTurnMeters?.round() ?? c.remainingRouteMeters.round()} м до указания · осталось ${(c.remainingRouteMeters / 1000).toStringAsFixed(1)} км',
        ),
      ),
    );
  }
}

class ReturnToStartButton extends StatelessWidget {
  const ReturnToStartButton({
    super.key,
    required this.controller,
    this.enabled = true,
  });
  final MapNavigationController controller;
  final bool enabled;
  @override
  Widget build(BuildContext context) => TextButton.icon(
    icon: const Icon(Icons.home_outlined),
    label: const Text('К старту'),
    onPressed:
        !enabled || !controller.canReturnToStart || controller.isLoadingRoute
        ? null
        : () async {
            final roads = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Вернуться к старту'),
                content: const Text(
                  'По записанному треку — без сети, с учётом разрывов GPS. Возможность обратного проезда нужно проверить.\n\nПо дорогам — новый маршрут через интернет.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Отмена'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('По треку'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('По дорогам'),
                  ),
                ],
              ),
            );
            if (roads == null || !context.mounted) return;
            try {
              if (roads) {
                await controller.returnToStartByRoads();
              } else {
                controller.returnAlongTrack();
              }
              if (context.mounted)
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      controller.routeNotice ?? 'Маршрут к старту готов',
                    ),
                  ),
                );
            } catch (error) {
              if (context.mounted)
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Не удалось подготовить возвращение: $error'),
                  ),
                );
            }
          },
  );
}
