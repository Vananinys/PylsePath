import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/data/workout_draft_store.dart';
import 'package:pulsepath/models/activity_type.dart';

class RejectBackups extends InMemorySharedPreferencesStore {
  RejectBackups(String original)
    : super.withData({'flutter.workout_draft_account-a': original});
  bool reject = true;
  int backupAttempts = 0;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key.contains('_damaged_')) {
      backupAttempts++;
      if (reject) return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const owner = 'account-a';
  final draft = WorkoutDraft(
    ownerId: owner,
    localId: 'ride-1',
    startedAt: DateTime.utc(2026, 10, 17, 8),
    activeMilliseconds: 125000,
    distanceMeters: 713.5,
    elevationGainMeters: 12.5,
    activity: ActivityType.cycling,
    path: const [LatLng(52.52, 13.405), LatLng(52.521, 13.406)],
    vehicleId: 'bike-1',
    isEbike: true,
  );

  test(
    'checkpoint survives a fresh store and remains account scoped',
    () async {
      await WorkoutDraftStore(owner).save(draft);
      final recovered = await WorkoutDraftStore(owner).load();
      expect(recovered?.localId, 'ride-1');
      expect(recovered?.activeMilliseconds, 125000);
      expect(recovered?.distanceMeters, 713.5);
      expect(recovered?.path, draft.path);
      expect(recovered?.vehicleId, 'bike-1');
      expect(await WorkoutDraftStore('account-b').load(), isNull);
      await WorkoutDraftStore(owner).delete();
      expect(await WorkoutDraftStore(owner).load(), isNull);
    },
  );

  test(
    'serialized checkpoint then deletion does not resurrect the ride',
    () async {
      final store = WorkoutDraftStore(owner);
      final saving = store.save(draft);
      final deletion = store.delete();
      await Future.wait([saving, deletion]);
      expect(await store.load(), isNull);
    },
  );

  test('rejects a corrupt track without deleting its stored bytes', () async {
    final store = WorkoutDraftStore(owner);
    await store.save(draft);
    final prefs = await SharedPreferences.getInstance();
    const key = 'workout_draft_$owner';
    await prefs.setString(
      key,
      '{"version":1,"ownerId":"account-a","path":[[999,0]]}',
    );
    await expectLater(store.load(), throwsFormatException);
    expect(prefs.getString(key), isNotNull);
  });
  test(
    'A new checkpoint preserves corrupt bytes even when load was not called',
    () async {
      final prefs = await SharedPreferences.getInstance();
      const key = 'workout_draft_$owner';
      const original = '{unfinished-gps';
      await prefs.setString(key, original);
      await WorkoutDraftStore(owner).save(draft);
      final backup = '${key}_damaged_${sha256.convert(utf8.encode(original))}';
      expect(prefs.getString(backup), original);
      expect((await WorkoutDraftStore(owner).load())?.localId, draft.localId);
      await WorkoutDraftStore(owner).save(draft);
      expect(
        prefs.getKeys().where(
          (key) => key.startsWith('workout_draft_${owner}_damaged_'),
        ),
        hasLength(1),
      );
    },
  );
  test('A rejected backup cannot be trusted through the optimistic preferences cache', () async {
    const original = '{broken-final-checkpoint';
    final platform = RejectBackups(original);
    SharedPreferencesStorePlatform.instance = platform;
    final prefs = await SharedPreferences.getInstance();
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(WorkoutDraftStore(owner).save(draft), throwsStateError);
      expect(
        (await platform.getAll())['flutter.workout_draft_$owner'],
        original,
      );
    }
    expect(platform.backupAttempts, 2);
    platform.reject = false;
    await WorkoutDraftStore(owner).save(draft);
    final backup =
        'flutter.workout_draft_${owner}_damaged_${sha256.convert(utf8.encode(original))}';
    expect((await platform.getAll())[backup], original);
    expect(prefs.getString('workout_draft_$owner'), isNot(original));
  });
}
