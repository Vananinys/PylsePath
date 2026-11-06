import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/saved_route.dart';

SavedRoute ride(String id) => SavedRoute(
  localId: id,
  title: id,
  distance: '1 км',
  duration: '5 мин',
  surfaceSummary: '',
  finishPoint: const LatLng(55, 83),
  routePoints: const [],
  activityType: ActivityType.cycling,
  createdAt: DateTime(2026, 11, 4),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'captureProgress failure after a written history entry is observable, not a failed save',
    () async {
      SharedPreferences.setMockInitialValues({});
      WorkoutHistoryRepository.resetInstancesForTesting();
      final repository = WorkoutHistoryRepository();
      var captureCalls = 0;
      repository.captureProgressForTesting = (rides) async {
        captureCalls++;
        throw StateError('backup unavailable');
      };

      // addWorkout не должен пробросить ошибку фиксации достижений:
      // запись истории уже успешна, завершение поездки провалом не считается.
      await repository.addWorkout(ride('ride-1'));

      expect(captureCalls, 1);
      expect(repository.lastAchievementsError, isA<StateError>());
      expect(repository.workoutHistory.map((r) => r.localId), ['ride-1']);

      // Повторное добавление того же заезда не создаёт дубль.
      await repository.addWorkout(ride('ride-1'));
      expect(repository.workoutHistory, hasLength(1));

      // Удачная фиксация достижений сбрасывает наблюдаемую ошибку.
      repository.captureProgressForTesting = null;
      await repository.addWorkout(ride('ride-2'));
      expect(repository.lastAchievementsError, isNull);
      expect(repository.workoutHistory, hasLength(2));
    },
  );

  test('successful captureProgress clears lastAchievementsError', () async {
    SharedPreferences.setMockInitialValues({});
    WorkoutHistoryRepository.resetInstancesForTesting();
    final repository = WorkoutHistoryRepository();
    repository.lastAchievementsError = StateError('stale');
    repository.captureProgressForTesting = (rides) async {};

    await repository.addWorkout(ride('ride-3'));

    expect(repository.lastAchievementsError, isNull);
  });
}
