import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'network_guard.dart';

const String historyKey = 'workout_history_guest';

Map<String, dynamic> damagedRide() => {
  'localId': 'damaged-telemetry',
  'title': 'Старая поездка с необязательной телеметрией',
  'distance': '1.00 км',
  'duration': '10 мин',
  'surfaceSummary': 'Записанный GPS-трек',
  'finishLat': 55.0,
  'finishLon': 83.001,
  'routePoints': [
    [55.0, 83.0],
    [55.0, 83.001],
  ],
  'activityType': 'cycling',
  'createdAt': '2026-10-01T10:00:00.000Z',
  'workoutDetails': {
    'segment_starts': [0, 2, -1],
    'samples': [
      {
        'seconds': 0,
        'meters': 0,
        'speed': 12.5,
        'elapsed': 0,
        'track_point_index': 0,
      },
      {'seconds': 10, 'meters': 100, 'speed': 987.654},
      {'seconds': -424242, 'meters': 200, 'speed': 20},
      'not-a-map',
      {
        'seconds': 20,
        'meters': 300,
        'speed': 20,
        'elapsed': 20,
        'track_point_index': 1,
      },
    ],
    'laps': [
      {'number': 1, 'meters': 100, 'seconds': 30, 'end': 30},
      {'number': 0, 'meters': -1, 'seconds': -1, 'end': 424242},
      {'number': 2, 'meters': 200, 'seconds': 30, 'end': 60},
    ],
    'ride_moments': [
      {'id': 'before-gap', 'kind': 'rest', 'point_index': 1, 'meters': 100},
      {
        'id': 'moment-sentinel-dropped',
        'kind': 'not-a-kind',
        'point_index': 1,
        'meters': 150,
      },
      {'id': 'after-gap', 'kind': 'climb', 'point_index': 1, 'meters': 200},
    ],
    'walking_steps': {
      'version': 1,
      'device': 'steps-sentinel-lost',
      'observed_at': 1000,
      'windows': [
        {'start': 500, 'end': 400, 'recorded': 10, 'live': 10},
      ],
    },
  },
};

Map<String, dynamic> newRide() => {
  'localId': 'new-ride',
  'title': 'Новая поездка',
  'distance': '0.50 км',
  'duration': '5 мин',
  'surfaceSummary': 'Записанный GPS-трек',
  'finishLat': 55.0,
  'finishLon': 83.0005,
  'routePoints': [
    [55.0, 83.0],
    [55.0, 83.0005],
  ],
  'activityType': 'cycling',
  'createdAt': '2026-10-02T10:00:00.000Z',
  'workoutDetails': {
    'samples': [
      {'seconds': 0, 'meters': 0, 'speed': 10.0},
    ],
  },
};

class RejectTelemetryBackup extends InMemorySharedPreferencesStore {
  RejectTelemetryBackup(String original, {String key = historyKey})
    : super.withData({'flutter.$key': original});
  int attempts = 0;
  bool reject = true;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key.contains('_damaged_')) {
      attempts++;
      if (reject) return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(NetworkGuard.install);
  tearDownAll(NetworkGuard.restore);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkoutHistoryRepository.resetInstancesForTesting();
  });

  test('optional telemetry remains readable and its original bytes survive the next save', () async {
    final prefs = await SharedPreferences.getInstance();
    final original = jsonEncode({
      'version': 2,
      'workouts': [damagedRide()],
      'deletedIds': <String>[],
      'pendingDeletes': <String>[],
    });
    await prefs.setString(historyKey, original);

    final history = WorkoutHistoryRepository();
    await history.load();
    expect(history.recoveryNotice, isNull);

    final loaded = history.workoutHistory.single;
    expect(loaded.localId, 'damaged-telemetry');
    expect(loaded.routePoints, hasLength(2));
    expect(loaded.workoutDetails.samples, hasLength(2));
    expect(loaded.workoutDetails.walkingSteps, isNull);
    expect(loaded.workoutDetails.laps.map((lap) => lap.number), [1, 2]);
    expect(loaded.workoutDetails.rideMoments.map((moment) => moment.id), [
      'before-gap',
      'after-gap',
    ]);
    expect(loaded.workoutDetails.segmentStarts, [0, 2]);

    // Reading a valid envelope must not rewrite it.
    expect(prefs.getString(historyKey), original);

    await history.addWorkout(SavedRoute.fromJson(newRide()));

    final after = prefs.getString(historyKey)!;
    expect(
      after,
      isNot(original),
      reason: 'saving a new ride rewrites the stored envelope',
    );

    final decoded = jsonDecode(after) as Map<String, dynamic>;
    final workouts = (decoded['workouts'] as List).cast<Map<String, dynamic>>();
    expect(workouts.map((ride) => ride['localId']), [
      'damaged-telemetry',
      'new-ride',
    ]);

    final stored = workouts.firstWhere(
      (ride) => ride['localId'] == 'damaged-telemetry',
    );
    final details = stored['workoutDetails'] as Map<String, dynamic>;
    expect(details['samples'], hasLength(2));
    expect(details['walking_steps'], isNull);
    expect((details['laps'] as List).map((lap) => lap['number']), [1, 2]);
    expect((details['ride_moments'] as List).map((moment) => moment['id']), [
      'before-gap',
      'after-gap',
    ]);
    expect(details['segment_starts'], [0, 2]);

    // Invalid values stay out of the active model but survive in the backup.
    const sentinels = [
      '987.654',
      '424242',
      'moment-sentinel-dropped',
      'steps-sentinel-lost',
    ];
    for (final sentinel in sentinels) {
      expect(
        after.contains(sentinel),
        isFalse,
        reason: 'normalized JSON still contains $sentinel',
      );
    }
    final allStrings = prefs
        .getKeys()
        .map((key) => prefs.get(key))
        .whereType<String>();
    expect(
      allStrings.any((value) => value == original),
      isTrue,
      reason: 'the complete original envelope must remain in a backup',
    );
    for (final sentinel in sentinels) {
      expect(
        allStrings.any((value) => value.contains(sentinel)),
        isTrue,
        reason: 'backup lost original telemetry $sentinel',
      );
    }
    expect(
      prefs.getKeys().where((key) => key.startsWith('${historyKey}_damaged_')),
      hasLength(1),
      reason: 'normalizing damaged optional data requires a backup',
    );

    WorkoutHistoryRepository.resetInstancesForTesting();
    final reopened = WorkoutHistoryRepository();
    await reopened.load();
    expect(reopened.workoutHistory.map((ride) => ride.localId), [
      'damaged-telemetry',
      'new-ride',
    ]);
  });

  test('a legacy list with the same optional damage is accepted, migrated and remains usable', () async {
    final prefs = await SharedPreferences.getInstance();
    final legacy = jsonEncode([damagedRide()]);
    await prefs.setString(historyKey, legacy);

    final history = WorkoutHistoryRepository();
    await history.load();
    expect(history.recoveryNotice, isNull);
    expect(history.workoutHistory.single.localId, 'damaged-telemetry');
    expect(history.workoutHistory.single.workoutDetails.samples, hasLength(2));

    // Reading a legacy list intentionally migrates it to envelope v2. This is
    // compatibility work, not a read error; the damaged optional fields are
    // still normalized and their original bytes are not kept.
    final migrated =
        jsonDecode(prefs.getString(historyKey)!) as Map<String, dynamic>;
    expect(migrated['version'], 2);
    expect(migrated['workouts'], hasLength(1));
    expect(
      prefs
          .getKeys()
          .where((key) => key.startsWith('${historyKey}_damaged_'))
          .map(prefs.getString),
      contains(legacy),
    );

    await history.addWorkout(SavedRoute.fromJson(newRide()));
    WorkoutHistoryRepository.resetInstancesForTesting();
    final reopened = WorkoutHistoryRepository();
    await reopened.load();
    expect(reopened.workoutHistory.map((ride) => ride.localId), [
      'damaged-telemetry',
      'new-ride',
    ]);
  });
  test('failed backup blocks overwrite and an optimistic cache cannot bypass retries', () async {
    final original = jsonEncode({
      'version': 2,
      'workouts': [damagedRide()],
    });
    final previous = SharedPreferencesStorePlatform.instance;
    final platform = RejectTelemetryBackup(original);
    SharedPreferencesStorePlatform.instance = platform;
    SharedPreferences.resetStatic();
    try {
      final history = WorkoutHistoryRepository();
      await expectLater(
        history.addWorkout(SavedRoute.fromJson(newRide())),
        throwsStateError,
      );
      await expectLater(
        history.addWorkout(SavedRoute.fromJson(newRide())),
        throwsStateError,
      );
      expect(platform.attempts, 2);
      expect((await platform.getAll())['flutter.$historyKey'], original);
      platform.reject = false;
      await history.addWorkout(SavedRoute.fromJson(newRide()));
      expect(
        (await platform.getAll()).entries
            .where((e) => e.key.contains('_damaged_'))
            .single
            .value,
        original,
      );
      expect(history.workoutHistory, hasLength(2));
    } finally {
      SharedPreferencesStorePlatform.instance = previous;
      SharedPreferences.resetStatic();
      WorkoutHistoryRepository.resetInstancesForTesting();
    }
  });

  test('normal telemetry does not create redundant backup archives', () async {
    final prefs = await SharedPreferences.getInstance();
    final route = SavedRoute.fromJson(newRide());
    await prefs.setString(
      historyKey,
      jsonEncode({
        'version': 2,
        'workouts': [route.toJson()],
      }),
    );
    final history = WorkoutHistoryRepository();
    await history.load();
    await history.save();
    expect(prefs.getKeys().where((key) => key.contains('_damaged_')), isEmpty);
  });

  test(
    'optional damage in the recovery archive also keeps original bytes',
    () async {
      final prefs = await SharedPreferences.getInstance();
      const recoveryKey = '${historyKey}_recovery_v1';
      final original = jsonEncode({
        'version': 2,
        'workouts': [damagedRide()],
      });
      await prefs.setString(recoveryKey, original);
      final history = WorkoutHistoryRepository();
      await history.addWorkout(SavedRoute.fromJson(newRide()));
      expect(
        prefs
            .getKeys()
            .where((key) => key.startsWith('${recoveryKey}_damaged_'))
            .map(prefs.getString),
        contains(original),
      );
      WorkoutHistoryRepository.resetInstancesForTesting();
      final reopened = WorkoutHistoryRepository();
      await reopened.load();
      expect(reopened.workoutHistory, hasLength(2));
    },
  );
  test(
    'a recovery archive backup failure also prevents normalization writes',
    () async {
      const recoveryKey = '${historyKey}_recovery_v1';
      final original = jsonEncode({
        'version': 2,
        'workouts': [damagedRide()],
      });
      final previous = SharedPreferencesStorePlatform.instance;
      final platform = RejectTelemetryBackup(original, key: recoveryKey);
      SharedPreferencesStorePlatform.instance = platform;
      SharedPreferences.resetStatic();
      try {
        final history = WorkoutHistoryRepository();
        await expectLater(
          history.addWorkout(SavedRoute.fromJson(newRide())),
          throwsStateError,
        );
        await expectLater(
          history.addWorkout(SavedRoute.fromJson(newRide())),
          throwsStateError,
        );
        expect((await platform.getAll())['flutter.$recoveryKey'], original);
        platform.reject = false;
        await history.addWorkout(SavedRoute.fromJson(newRide()));
        expect(history.workoutHistory, hasLength(2));
      } finally {
        SharedPreferencesStorePlatform.instance = previous;
        SharedPreferences.resetStatic();
        WorkoutHistoryRepository.resetInstancesForTesting();
      }
    },
  );
}
