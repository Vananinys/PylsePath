import 'package:flutter/material.dart';

import '../models/saved_route.dart';
import '../models/shared_route.dart';
import 'route_trace_preview.dart';

class TrackPrivacyPicker extends StatelessWidget {
  const TrackPrivacyPicker({
    super.key,
    required this.route,
    required this.enabled,
    required this.radius,
    required this.onEnabled,
    required this.onRadius,
  });
  final SavedRoute route;
  final bool enabled;
  final int radius;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<int> onRadius;

  @override
  Widget build(BuildContext context) {
    final snapshot = enabled
        ? SharedRoute.fromSavedRoute(route, hideRadiusMeters: radius.toDouble())
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Показать трек и разрешить GPX'),
          subtitle: const Text('Трек будет доступен читателям поста'),
          value: enabled,
          onChanged: route.routePoints.length >= 2 ? onEnabled : null,
        ),
        if (enabled) ...[
          DropdownButtonFormField<int>(
            initialValue: radius,
            decoration: const InputDecoration(
              labelText: 'Скрыть область начала и финиша',
            ),
            items: [
              for (final meters in [0, 200, 500, 1000])
                DropdownMenuItem(
                  value: meters,
                  child: Text(
                    meters == 0 ? 'Показать весь трек' : 'Радиус $meters м',
                  ),
                ),
            ],
            onChanged: (value) {
              if (value != null) onRadius(value);
            },
          ),
          const SizedBox(height: 10),
          if (snapshot!.points.length >= 2)
            SizedBox(
              height: 120,
              child: RouteTracePreview(
                points: snapshot.points,
                segmentStarts: snapshot.segmentStarts,
              ),
            )
          else
            const Text(
              'Весь трек попадает в скрытые области. В посте останется только статистика.',
            ),
          const SizedBox(height: 6),
          const Text(
            'Предпросмотр линии для этой публикации. Скрытые точки не входят и в GPX.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ],
    );
  }
}
