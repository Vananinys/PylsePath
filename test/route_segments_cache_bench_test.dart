import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/workout_details.dart';
import 'package:pulsepath/utils/geo_utils.dart';

/// Информационные замеры стоимости доступа к сегментам маршрута и полного
/// вычисления отклонения. Абсолютные значения зависят от машины и jit/aot —
/// их не проверяем assert'ами, только печатаем и сравниваем кэш против
/// прямого пересчёта того же объёма.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MapNavigationController controller;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkoutHistoryRepository.resetInstancesForTesting();
    controller = MapNavigationController();
  });
  tearDown(() => controller.dispose());

  test('Segment access and deviation cost with and without cache', () {
    const pointsCount = 5000;
    final points = [
      for (var i = 0; i < pointsCount; i++)
        LatLng(55.0 + i * 0.0005, 83.0 + (i % 3 == 0 ? 0 : 0.0005)),
    ];
    final gapStarts = [
      for (var i = 0; i < pointsCount; i += 500) i,
    ];
    final sortedStarts = [...gapStarts]..sort();

    // Прямой пересчёт разбиения — то, что делал старый геттер на каждый вызов.
    const rebuilds = 20;
    final splitWatch = Stopwatch()..start();
    for (var i = 0; i < rebuilds; i++) {
      WorkoutDetails.splitTrack(points, sortedStarts);
    }
    splitWatch.stop();

    // Полное вычисление отклонения по старому пути: пересчёт сегментов на
    // каждой GPS-точке + fold по сегментам — то, что делал старый геттер.
    const point = LatLng(55.25, 83.0007);
    const deviationCalls = 20;
    final deviationWatch = Stopwatch()..start();
    for (var i = 0; i < deviationCalls; i++) {
      WorkoutDetails.splitTrack(points, sortedStarts).fold<double>(
        double.infinity,
        (best, segment) =>
            _min(best, GeoUtils.minDistanceToPolyline(point, segment)),
      );
    }
    deviationWatch.stop();

    // Кэшированный доступ через контроллер.
    expect(controller.loadImportedTrack(points, segmentStarts: gapStarts), isTrue);
    final first = controller.routeSegments; // прогрев: строит кэш
    const cacheHits = 10000;
    final cacheWatch = Stopwatch()..start();
    for (var i = 0; i < cacheHits; i++) {
      controller.routeSegments;
    }
    cacheWatch.stop();
    final cachedSegments = controller.routeSegments;
    expect(cachedSegments, WorkoutDetails.splitTrack(points, sortedStarts));

    // Отклонение по кэшированным сегментам: fold без пересчёта разбиения.
    final cachedDeviationWatch = Stopwatch()..start();
    for (var i = 0; i < deviationCalls; i++) {
      cachedSegments.fold<double>(
        double.infinity,
        (best, segment) => _min(
          best,
          GeoUtils.minDistanceToPolyline(point, segment),
        ),
      );
    }
    cachedDeviationWatch.stop();

    // ignore: avoid_print
    print('routeSegments bench ($pointsCount точек, '
        '${sortedStarts.length} разрывов):');
    // ignore: avoid_print
    print('  прямой splitTrack: '
        '${splitWatch.elapsedMicroseconds / rebuilds} мкс/вызов');
    // ignore: avoid_print
    print('  полное отклонение по старому пути (пересчёт+fold): '
        '${deviationWatch.elapsedMicroseconds / deviationCalls} мкс/точку');
    // ignore: avoid_print
    print('  кэшированный доступ routeSegments: '
        '${cacheWatch.elapsedMicroseconds / cacheHits} мкс/вызов');
    // ignore: avoid_print
    print('  полное отклонение по кэшу (только fold): '
        '${cachedDeviationWatch.elapsedMicroseconds / deviationCalls} мкс/точку');
    expect(first, isNotEmpty);
  });
}

double _min(double a, double b) => a < b ? a : b;
