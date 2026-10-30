import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../controllers/map_navigation_controller.dart';

class RouteWaypointsEditor extends StatelessWidget {
  const RouteWaypointsEditor({
    super.key,
    required this.controller,
    required this.onChange,
  });
  final MapNavigationController controller;
  final Future<void> Function(List<LatLng>) onChange;
  @override
  Widget build(BuildContext context) {
    final via = controller.routeWaypoints;
    if (controller.followsSavedTrack) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          'Остановки · ${via.length} / 8',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        Text(
          'Удерживайте точку на карте и выберите «Добавить остановку».',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        for (var i = 0; i < via.length; i++)
          Row(
            children: [
              Text(
                '${i + 1}. ',
                style: const TextStyle(
                  color: Colors.deepOrange,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Expanded(
                child: Text(
                  '${via[i].latitude.toStringAsFixed(4)}, ${via[i].longitude.toStringAsFixed(4)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Передвинуть остановку выше',
                visualDensity: VisualDensity.compact,
                onPressed: !controller.canEditWaypoints || i == 0
                    ? null
                    : () {
                        final updated = List<LatLng>.of(via);
                        final point = updated.removeAt(i);
                        updated.insert(i - 1, point);
                        onChange(updated);
                      },
                icon: const Icon(Icons.arrow_upward, size: 18),
              ),
              IconButton(
                tooltip: 'Удалить остановку',
                visualDensity: VisualDensity.compact,
                onPressed: !controller.canEditWaypoints
                    ? null
                    : () {
                        final updated = List<LatLng>.of(via)..removeAt(i);
                        onChange(updated);
                      },
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        if (controller.isNavigating && via.isNotEmpty)
          Text(
            'Для изменения остановок остановите навигацию.',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
