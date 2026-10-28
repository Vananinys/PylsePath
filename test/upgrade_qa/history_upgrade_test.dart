// Upgrade / downgrade compatibility of the local workout history.
//
// Every assertion reads the fake platform store (the durable layer), never only
// the optimistic SharedPreferences cache.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../deepseek_integrity/network_guard.dart';
import 'qa_support.dart';

const historyKey = 'workout_history_guest';
const recoveryKey = '${historyKey}_recovery_v1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(NetworkGuard.install);
  tearDownAll(NetworkGuard.restore);

  late QaPreferencesStore platform;
  late SharedPreferencesStorePlatform previousPlatform;

  setUp(() {
    previousPlatform = SharedPreferencesStorePlatform.instance;
    platform = QaPreferencesStore();
    SharedPreferencesStorePlatform.instance = platform;
    SharedPreferences.resetStatic();
    WorkoutHistoryRepository.resetInstancesForTesting();
  });

  tearDown(() {
    SharedPreferencesStorePlatform.instance = previousPlatform;
    SharedPreferences.resetStatic();
    WorkoutHistoryRepository.resetInstancesForTesting();
  });

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  Future<Object?> durable(String key) async =>
      (await platform.getAll())['flutter.$key'];

  Future<List<String>> damagedValues(String key) async {
    final all = await platform.getAll();
    return [
      for (final entry in all.entries)
        if (entry.key.startsWith('flutter.${key}_damaged_'))
          entry.value as String,
    ];
  }

  Future<void> restart() async {
    SharedPreferences.resetStatic();
    WorkoutHistoryRepository.resetInstancesForTesting();
  }

  test(
    'legacy list is migrated once and keeps identity, date and activity type',
    () async {
      final store = await prefs();
      await store.setString(
        historyKey,
        jsonEncode([
          workoutRow(
            remoteId: 'cloud-legacy-1',
            activityType: null,
            activityIndex: 4,
            createdAt: 1790848800000,
            newFields: false,
          ),
          workoutRow(
            localId: 'local-legacy-2',
            activityType: null,
            activityIndex: 1,
            createdAt: 1790935200000,
            newFields: false,
          ),
        ]),
      );

      final history = WorkoutHistoryRepository();
      await history.load();
      expect(history.workoutHistory.map((ride) => ride.localId), [
        'cloud-legacy-1',
        'local-legacy-2',
      ]);

      final stored = jsonDecode(
        (await durable(historyKey)) as String,
      ) as Map<String, dynamic>;
      expect(stored['version'], 2, reason: 'legacy list must be migrated once');
      final rows = (stored['workouts'] as List).cast<Map<String, dynamic>>();
      expect(rows.map((row) => row['localId']), [
        'cloud-legacy-1',
        'local-legacy-2',
      ]);
      expect(rows[0]['activityType'], 'cycling');
      expect(rows[1]['activityType'], 'roadCycling');
      expect(
        DateTime.parse(rows[0]['createdAt'] as String),
        DateTime.fromMillisecondsSinceEpoch(1790848800000),
      );

      await history.addWorkout(
        SavedRoute.fromJson(workoutRow(localId: 'new-1')),
      );
      await restart();
      final reopened = WorkoutHistoryRepository();
      await reopened.load();
      expect(reopened.workoutHistory.map((ride) => ride.localId), [
        'cloud-legacy-1',
        'local-legacy-2',
        'new-1',
      ]);
      expect(await damagedValues(historyKey), isEmpty);
    },
  );

  test(
    'missing new fields and explicit nulls stay readable and survive save',
    () async {
      final store = await prefs();
      await store.setString(
        historyKey,
        jsonEncode(
          historyEnvelope([
            workoutRow(
              localId: 'nulls',
              newFields: false,
              extra: {
                'distanceMeters': null,
                'durationSeconds': null,
                'calories': null,
                'elevationGain': null,
                'activityLocalDay': null,
                'remoteId': null,
                'cloudSynced': null,
              },
            ),
          ]),
        ),
      );

      final history = WorkoutHistoryRepository();
      await history.load();
      final loaded = history.workoutHistory.single;
      expect(loaded.localId, 'nulls');
      expect(loaded.routePoints, hasLength(2));
      expect(loaded.distanceKm, 12.5, reason: 'legacy distance string');
      expect(loaded.durationSeconds, isNull);
      expect(loaded.cloudSynced, isFalse);

      await history.save();
      await restart();
      final reopened = WorkoutHistoryRepository();
      await reopened.load();
      final restored = reopened.workoutHistory.single;
      expect(restored.localId, 'nulls');
      expect(restored.routePoints, hasLength(2));
      expect(restored.createdAt, DateTime.utc(2026, 10, 1, 10));
      expect(
        await damagedValues(historyKey),
        isEmpty,
        reason: 'explicit nulls are valid data, not damage',
      );
    },
  );

  test('unknown row fields survive a save of a newer-schema history or are archived', () async {
    final store = await prefs();
    await store.setString(
      historyKey,
      jsonEncode(
        historyEnvelope([
          workoutRow(
            localId: 'future-row',
            extra: {
              'weather_v2': {'temp_c': 7, 'provider': 'qa'},
              'schema_rev': 99,
            },
          ),
        ]),
      ),
    );

    final original = await durable(historyKey) as String;
    final history = WorkoutHistoryRepository();
    await history.load();
    expect(history.recoveryNotice, isNull);
    await history.addWorkout(SavedRoute.fromJson(workoutRow(localId: 'new-2')));

    expect(await damagedValues(historyKey), contains(original));
    final stored = await durable(historyKey) as String;
    final archived = (await damagedValues(historyKey))
        .any((value) => value.contains('temp_c'));
    expect(
      stored.contains('temp_c') || archived,
      isTrue,
      reason:
          'a row field written by a newer build was silently discarded by '
          'the older build: no original backup exists and the only copy is '
          'gone',
    );
  });

  test('a newer envelope version is preserved and new rides use the recovery archive', () async {
    final store = await prefs();
    final original = jsonEncode(
      historyEnvelope(
        [workoutRow(localId: 'future-1')],
        version: 3,
        extra: {'epoch': 9},
      ),
    );
    await store.setString(historyKey, original);

    final history = WorkoutHistoryRepository();
    await history.load();
    expect(history.recoveryNotice, isNotNull);
    expect(await durable(historyKey), original);
    expect(await damagedValues(historyKey), [original]);

    await history.addWorkout(SavedRoute.fromJson(workoutRow(localId: 'new-3')));
    expect(
      await durable(historyKey),
      original,
      reason: 'a future primary envelope must never be overwritten',
    );
    final recovery = jsonDecode(
      (await durable(recoveryKey)) as String,
    ) as Map<String, dynamic>;
    expect(recovery['version'], 2);
    expect((recovery['workouts'] as List).map((row) => row['localId']), [
      'new-3',
    ]);

    await restart();
    final reopened = WorkoutHistoryRepository();
    await reopened.load();
    expect(reopened.workoutHistory.map((ride) => ride.localId), ['new-3']);
    expect(await durable(historyKey), original);
  });

  test('a rejected primary write reports failure and never claims the ride was saved', () async {
    final store = await prefs();
    final original = jsonEncode(
      historyEnvelope([workoutRow(localId: 'kept-1')]),
    );
    await store.setString(historyKey, original);
    platform.rejectWritesTo(historyKey);

    final history = WorkoutHistoryRepository();
    await expectLater(
      history.addWorkout(SavedRoute.fromJson(workoutRow(localId: 'lost-1'))),
      throwsStateError,
    );
    expect(await durable(historyKey), original);
    expect(await durable(recoveryKey), isNull);

    platform.allowWrites();
    await restart();
    final retried = WorkoutHistoryRepository();
    await retried.addWorkout(
      SavedRoute.fromJson(workoutRow(localId: 'lost-1')),
    );
    final recovered = jsonDecode(
      (await durable(historyKey)) as String,
    ) as Map<String, dynamic>;
    expect((recovered['workouts'] as List).map((row) => row['localId']), [
      'kept-1',
      'lost-1',
    ]);
  });

  test('an unreadable recovery archive blocks writes and keeps every original byte', () async {
    final store = await prefs();
    final original = jsonEncode(
      historyEnvelope([workoutRow(localId: 'future-recovery')], version: 3),
    );
    await store.setString(recoveryKey, original);

    final history = WorkoutHistoryRepository();
    await expectLater(history.load(), throwsFormatException);
    expect(await durable(recoveryKey), original);
    expect(await durable(historyKey), isNull);

    await expectLater(
      history.addWorkout(SavedRoute.fromJson(workoutRow(localId: 'new-4'))),
      throwsFormatException,
    );
    expect(await durable(recoveryKey), original);
    expect(await durable(historyKey), isNull);
    expect(
      (await damagedValues(recoveryKey)).single,
      original,
      reason: 'the future recovery archive must be archived verbatim',
    );
  });
}
