import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/activity_type.dart';
import '../models/saved_route.dart';
import '../models/workout_details.dart';

/// Preview-only fixtures. Never passed to a history repository or uploader.
class DeveloperScenarios {
  static List<SavedRoute> heatmap({DateTime? now}) {
    final date = now ?? DateTime.now();
    return [
      for (var ride = 0; ride < 14; ride++)
        SavedRoute(
          localId: 'preview-$ride',
          title: 'Тестовый маршрут ${ride + 1}',
          distance: '4.2 км',
          duration: '24 мин',
          surfaceSummary: 'Только предпросмотр',
          finishPoint: const LatLng(52.54, 85.2),
          activityType: ride % 3 == 0
              ? ActivityType.running
              : ActivityType.mountainBiking,
          createdAt: date.subtract(Duration(days: ride * 8)),
          workoutDetails: WorkoutDetails(
            segmentStarts: ride == 13 ? const [0, 50] : const [0],
          ),
          routePoints: [
            for (var i = 0; i < 100; i++)
              LatLng(
                52.54 + .008 * math.sin(i / 99 * math.pi * 2),
                85.2 +
                    .013 * math.cos(i / 99 * math.pi * 2) +
                    (ride > 9 ? .004 : 0),
              ),
          ],
        ),
    ];
  }
}
