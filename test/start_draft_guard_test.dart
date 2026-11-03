import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/data/workout_draft_store.dart';

WorkoutDraft draft(String localId) => WorkoutDraft(
  ownerId: 'account-a',
  localId: localId,
  startedAt: DateTime.utc(2026, 11, 3, 9),
  activeMilliseconds: 60000,
  distanceMeters: 300,
  elevationGainMeters: 5,
  activity: ActivityType.cycling,
  path: const [LatLng(55.0, 83.0), LatLng(55.001, 83.0)],
);

Map<String, dynamic> historyRide(String id) => {
  'localId': id,
  'title': 'Saved ride',
  'distance': '1 km',
  'duration': '10 min',
  'surfaceSummary': '',
  'finishLat': 55.0,
  'finishLon': 83.001,
  'routePoints': [
    [55.0, 83.0],
    [55.0, 83.001],
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MapNavigationController controller;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkoutHistoryRepository.resetInstancesForTesting();
    controller = MapNavigationController(ownerResolver: () => 'account-a');
  });
  tearDown(() => controller.dispose());

  test('Unrestored draft blocks the start and its bytes stay on disk', () async {
    final prefs = await SharedPreferences.getInstance();
    const draftKey = 'workout_draft_account-a';
    final stored = jsonEncode(draft('old-ride').toJson());
    await prefs.setString(draftKey, stored);

    await expectLater(
      controller.ensureNoUnresolvedDraft(),
      throwsA(isA<InterruptedWorkoutBlockedException>()),
    );
    // Пока загрузка восстановления (_offerWorkoutRecovery) ещё идёт, повторный
    // гейт обязан прочитать актуальное состояние диска и снова заблокировать.
    final recovery = controller.loadInterruptedWorkout();
    await expectLater(
      controller.ensureNoUnresolvedDraft(),
      throwsA(isA<InterruptedWorkoutBlockedException>()),
    );
    expect(await recovery, isNotNull);
    // Черновик не удалён и не перезаписан.
    expect(prefs.getString(draftKey), stored);
  });

  test(
    'Stale draft whose ride already reached history is cleared, start allowed',
    () async {
      final prefs = await SharedPreferences.getInstance();
      const draftKey = 'workout_draft_account-a';
      await prefs.setString(
        draftKey,
        jsonEncode(draft('done-ride').toJson()),
      );
      await prefs.setString(
        'workout_history_guest',
        jsonEncode({
          'version': 2,
          'workouts': [historyRide('done-ride')],
          'deletedIds': <String>[],
          'pendingDeletes': <String>[],
        }),
      );

      await controller.ensureNoUnresolvedDraft();
      expect(prefs.getString(draftKey), isNull);
    },
  );

  test(
    'Damaged draft does not block the start and is backed up by the first checkpoint',
    () async {
      final prefs = await SharedPreferences.getInstance();
      const draftKey = 'workout_draft_account-a';
      const original = '{unfinished-gps';
      await prefs.setString(draftKey, original);

      await controller.ensureNoUnresolvedDraft();
      controller.startWorkout();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final backupKey = prefs.getKeys().singleWhere(
        (key) => key.startsWith('${draftKey}_damaged_'),
      );
      expect(prefs.getString(backupKey), original);
      expect(prefs.getString(draftKey), isNot(original));
      expect(controller.workoutSessionId, isNotNull);
    },
  );

  test(
    'Achievements failure after a written history entry is observable, not a failed finish',
    () async {
      final repository = WorkoutHistoryRepository();
      var captureCalls = 0;
      repository.captureProgressForTesting = (rides) async {
        captureCalls++;
        throw StateError('backup unavailable');
      };

      controller.startWorkout();
      final sessionId = controller.workoutSessionId;
      SavedRoute? saved;
      Object? finishError;
      try {
        saved = await controller.finishAndSaveWorkout(title: 'Проверка');
      } catch (error) {
        finishError = error;
      }

      // Завершение не объявляется проваленным, поездка сохранена ровно один раз.
      expect(finishError, isNull);
      expect(saved, isNotNull);
      expect(saved!.localId, sessionId);
      expect(captureCalls, 1);
      expect(repository.lastAchievementsError, isA<StateError>());
      expect(repository.workoutHistory.map((r) => r.localId), [sessionId]);

      // Повторное добавление того же заезда не создаёт дубль.
      await repository.addWorkout(saved);
      expect(repository.workoutHistory, hasLength(1));

      // Удачная фиксация достижений сбрасывает наблюдаемую ошибку.
      repository.captureProgressForTesting = null;
      await repository.addWorkout(SavedRoute.fromJson(historyRide('other')));
      expect(repository.lastAchievementsError, isNull);
    },
  );
}
