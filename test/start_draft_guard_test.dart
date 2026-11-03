import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/data/user_scope.dart';
import 'package:pulsepath/data/workout_draft_store.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/data/workout_history_repository.dart';

// Владелец подменяется через ownerResolver вместо реального Supabase-сеанса:
// в тестовой среде setUp() сбрасывает mock-хранилище shared_preferences, что
// теряло персистентную сессию и делало контроллера гостем (см. поведение
// loadInterruptedWorkout: гостевой черновик нечитаем). Репозиторий истории
// остаётся гостевым (его owner берётся из UserScope напрямую), поэтому
// конверт истории сеется под ключом _guest.
const uid = '00000000-0000-4000-8000-000000000001';

WorkoutDraft draft(String localId) => WorkoutDraft(
  ownerId: uid,
  localId: localId,
  startedAt: DateTime.utc(2026, 11, 4, 9),
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
    controller = MapNavigationController(ownerResolver: () => uid);
  });
  tearDown(() => controller.dispose());

  test('Unresolved draft blocks the start and its bytes stay on disk', () async {
    final prefs = await SharedPreferences.getInstance();
    final draftKey = UserScope.keyFor('workout_draft', uid);
    final stored = jsonEncode(draft('old-ride').toJson());
    await prefs.setString(draftKey, stored);

    await expectLater(
      controller.startWorkoutSafely(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Сначала восстановите или сохраните прерванную поездку',
        ),
      ),
    );
    // Пока загрузка восстановления (_offerWorkoutRecovery) ещё идёт,
    // повторный гейт обязан перечитать актуальное состояние диска
    // и снова заблокировать: перечитывание — часть контракта.
    final recovery = controller.loadInterruptedWorkout();
    await expectLater(
      controller.startWorkoutSafely(),
      throwsA(isA<StateError>()),
    );
    expect(await recovery, isNotNull);
    // Черновик не удалён и не перезаписан.
    expect(prefs.getString(draftKey), stored);
  });

  test('Stale draft whose ride already reached history is cleared', () async {
    final prefs = await SharedPreferences.getInstance();
    final draftKey = UserScope.keyFor('workout_draft', uid);
    await prefs.setString(draftKey, jsonEncode(draft('done-ride').toJson()));
    await prefs.setString(
      'workout_history_guest',
      jsonEncode({
        'version': 2,
        'workouts': [historyRide('done-ride')],
        'deletedIds': <String>[],
        'pendingDeletes': <String>[],
      }),
    );

    // Проверка прошла (устаревший черновик удалён), старт выполнен.
    expect(await controller.startWorkoutSafely(), isTrue);
    expect(prefs.getString(draftKey), isNull);
    expect(controller.workoutSessionId, isNotNull);
  });

  test('Damaged draft does not block the start and is backed up', () async {
    final prefs = await SharedPreferences.getInstance();
    final draftKey = UserScope.keyFor('workout_draft', uid);
    const original = '{unfinished-gps';
    await prefs.setString(draftKey, original);

    expect(await controller.startWorkoutSafely(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final backupKey = prefs.getKeys().singleWhere(
      (key) => key.startsWith('${draftKey}_damaged_'),
    );
    expect(prefs.getString(backupKey), original);
    expect(prefs.getString(draftKey), isNot(original));
    expect(controller.workoutSessionId, isNotNull);
  });

  test(
    'Two concurrent starts cannot pass the draft check together',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final draftKey = UserScope.keyFor('workout_draft', uid);
      await prefs.setString(draftKey, jsonEncode(draft('old-ride').toJson()));

      // Первый вызов уходит в await проверки хранилища; второй обязан
      // отклониться синхронно, а не пройти проверку параллельно.
      final first = controller.startWorkoutSafely();
      await expectLater(
        controller.startWorkoutSafely(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Старт поездки уже выполняется',
          ),
        ),
      );
      await expectLater(first, throwsA(isA<StateError>()));
      // Оба старта отклонены: черновик не перезаписан, сессии нет.
      expect(prefs.getString(draftKey), isNotNull);
      expect(controller.workoutSessionId, isNull);
    },
  );

  test('Guard releases after a completed start attempt', () async {
    // Без черновика: первый вызов стартует, флаг сбрасывается в finally —
    // последующий вызов больше не блокируется защитой параллельности.
    expect(await controller.startWorkoutSafely(), isTrue);
    expect(controller.isWorkoutActive, isTrue);
  });
}
