import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/services/owner_service.dart';

Map<String, dynamic> ride(String id) => {
  'localId': id,
  'title': 'Recorded ride',
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
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkoutHistoryRepository.resetInstancesForTesting();
  });

  test(
    'damaged original is preserved while new rides use a recovery archive',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'workout_history_guest',
        jsonEncode([ride('good')]),
      );
      final history = WorkoutHistoryRepository();
      await history.load();
      final damaged = jsonEncode({
        'version': 2,
        'workouts': [
          ride('good'),
          {...ride('bad'), 'title': 123},
        ],
      });
      await prefs.setString('workout_history_guest', damaged);
      await history.load();
      expect(history.workoutHistory.single.localId, 'good');
      await history.save();
      await history.addWorkout(SavedRoute.fromJson(ride('new')));
      expect(history.recoveryNotice, isNotNull);
      WorkoutHistoryRepository.resetInstancesForTesting();
      final reopened = WorkoutHistoryRepository();
      await reopened.load();
      expect(reopened.workoutHistory.map((r) => r.localId), ['good', 'new']);
      expect(prefs.getString('workout_history_guest'), damaged);
    },
  );

  test(
    'different corruptions keep independent copies and legacy damaged key',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('workout_history_guest_damaged', 'older-original');
      final history = WorkoutHistoryRepository();
      for (final original in ['{first', '{second', '{first']) {
        await prefs.setString('workout_history_guest', original);
        await history.load();
        final hash = sha256.convert(utf8.encode(original));
        expect(
          prefs.getString('workout_history_guest_damaged_$hash'),
          original,
        );
        expect(prefs.getString('workout_history_guest'), original);
      }
      expect(
        prefs.getKeys().where(
          (k) => k.startsWith('workout_history_guest_damaged_'),
        ),
        hasLength(2),
      );
      expect(
        prefs.getString('workout_history_guest_damaged'),
        'older-original',
      );
      await prefs.setString(
        'workout_history_guest',
        jsonEncode([ride('restored')]),
      );
      await history.load();
      await history.addWorkout(SavedRoute.fromJson(ride('new')));
      expect(history.workoutHistory.map((r) => r.localId), ['restored', 'new']);
    },
  );

  test(
    'missing workouts in an envelope is not treated as an empty history',
    () async {
      final prefs = await SharedPreferences.getInstance();
      const original = '{"version":2,"pendingDeletes":["a"]}';
      await prefs.setString('workout_history_guest', original);
      await WorkoutHistoryRepository().load();
      expect(WorkoutHistoryRepository().recoveryNotice, isNotNull);
      expect(prefs.getString('workout_history_guest'), original);
    },
  );

  test(
    'invalid GPS points are rejected instead of shifting moments and gaps',
    () {
      final json = {
        ...ride('gps'),
        'routePoints': [
          [55.0, 83.0],
          [91.0, 83.0],
          [55.0, 83.002],
          [55.0, 83.003],
        ],
        'workoutDetails': {
          'segment_starts': [0, 2],
          'ride_moments': [
            {'id': 'moment', 'kind': 'rest', 'point_index': 2, 'meters': 100.0},
          ],
        },
      };
      expect(() => SavedRoute.fromJson(json), throwsFormatException);
      (json['routePoints'] as List)[1] = [55.0, 83.001];
      final restored = SavedRoute.fromJson(json);
      expect(
        restored
            .routePoints[restored.workoutDetails.rideMoments.single.pointIndex]
            .longitude,
        83.002,
      );
      expect(restored.workoutDetails.segmentStarts, [0, 2]);
    },
  );

  test(
    'owner writes report failure when no account service is available',
    () async {
      final owner = OwnerService();
      await expectLater(owner.save({'title': 'test'}), throwsStateError);
      await expectLater(owner.saveTitle({'title': 'test'}), throwsStateError);
      await expectLater(
        owner.grant(
          kind: 'achievement',
          key: 'builtin:test',
          label: 'test',
          icon: 'x',
        ),
        throwsStateError,
      );
      await expectLater(owner.grantTitle('test'), throwsStateError);
      await expectLater(owner.revoke('test'), throwsStateError);
      await expectLater(
        owner.manageRecipients(action: 'grant', kind: 'title', key: 'test'),
        throwsStateError,
      );
    },
  );
  test('Unreadable tombstones prevent automatic cloud resurrection while new rides save', () async {
    final prefs = await SharedPreferences.getInstance();
    const original = '{broken-envelope';
    await prefs.setString('workout_history_guest', original);
    final history = WorkoutHistoryRepository();
    await history.addWorkout(SavedRoute.fromJson(ride('new-safe')));
    expect(
      await history.mergeRemote([SavedRoute.fromJson(ride('old-cloud'))]),
      0,
    );
    expect(history.workoutHistory.map((r) => r.localId), ['new-safe']);
    expect(prefs.getString('workout_history_guest'), original);
    WorkoutHistoryRepository.resetInstancesForTesting();
    final reopened = WorkoutHistoryRepository();
    await reopened.load();
    expect(reopened.workoutHistory.single.localId, 'new-safe');
  });
  test(
    'Saving a fresh repository cannot replace unreadable primary history',
    () async {
      final prefs = await SharedPreferences.getInstance();
      const original = '{preserve-before-load';
      await prefs.setString('workout_history_guest', original);
      final history = WorkoutHistoryRepository();
      await history.save();
      expect(prefs.getString('workout_history_guest'), original);
      expect(prefs.getString('workout_history_guest_recovery_v1'), isNotNull);
    },
  );
}
