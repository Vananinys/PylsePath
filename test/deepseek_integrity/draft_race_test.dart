import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/data/workout_draft_store.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Test-only fake of the platform store; adding it as a direct dependency is
// unnecessary and would change pubspec according to the task constraints.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'network_guard.dart';

const String owner = 'owner-draft-race';
const String storageKey = 'flutter.workout_draft_$owner';

/// SharedPreferences updates its in-memory cache before the platform confirms
/// the write. This store lets a test hold that confirmation open with a
/// [Completer], so operation order is deterministic and does not depend on
/// sleeps or wall-clock timing.
class GatedPreferences extends InMemorySharedPreferencesStore {
  GatedPreferences() : super.empty();

  final Map<String, Completer<void>> _entered = {};
  final Map<String, Completer<void>> _release = {};

  void blockValueContaining(String sentinel) {
    _entered[sentinel] = Completer<void>();
    _release[sentinel] = Completer<void>();
  }

  Future<void> waitForEntered(String sentinel) => _entered[sentinel]!.future;

  void releaseValue(String sentinel) {
    final gate = _release[sentinel];
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final text = value.toString();
    for (final entry in _entered.entries) {
      if (text.contains(entry.key)) {
        if (!entry.value.isCompleted) entry.value.complete();
        await _release[entry.key]!.future;
        break;
      }
    }
    return super.setValue(valueType, key, value);
  }
}

WorkoutDraft draft(String localId) => WorkoutDraft(
  ownerId: owner,
  localId: localId,
  startedAt: DateTime.utc(2026, 10, 28, 8),
  activeMilliseconds: 60000,
  distanceMeters: 1000,
  elevationGainMeters: 3,
  activity: ActivityType.cycling,
  path: const [LatLng(55, 83), LatLng(55.001, 83.001)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(NetworkGuard.install);
  tearDownAll(NetworkGuard.restore);

  late SharedPreferencesStorePlatform previousPlatform;
  late GatedPreferences platform;

  setUp(() {
    previousPlatform = SharedPreferencesStorePlatform.instance;
    platform = GatedPreferences();
    SharedPreferencesStorePlatform.instance = platform;
    SharedPreferences.resetStatic();
  });

  tearDown(() {
    SharedPreferencesStorePlatform.instance = previousPlatform;
    SharedPreferences.resetStatic();
  });

  test('a new store load waits for platform confirmation of the previous checkpoint', () async {
    final oldStore = WorkoutDraftStore(owner);
    final newStore = WorkoutDraftStore(owner);
    platform.blockValueContaining('draft-1');

    final saving = oldStore.save(draft('draft-1'));
    await platform.waitForEntered('draft-1');

    var readCompleted = false;
    final reading = newStore.load().then((value) {
      readCompleted = true;
      return value;
    });

    // The value came from SharedPreferences' optimistic cache: the platform
    // has not confirmed this write yet.
    final durableBefore = await platform.getAll();
    expect(durableBefore.containsKey(storageKey), isFalse);
    expect(readCompleted, isFalse);

    platform.releaseValue('draft-1');
    await saving;
    expect((await reading)?.localId, 'draft-1');

    final durableAfter = await platform.getAll();
    expect(durableAfter[storageKey], contains('draft-1'));
  });

  test(
    'a late save must not resurrect a draft after another instance deleted it',
    () async {
      final oldStore = WorkoutDraftStore(owner);
      final newStore = WorkoutDraftStore(owner);
      platform.blockValueContaining('draft-1');

      final saving = oldStore.save(draft('draft-1'));
      await platform.waitForEntered('draft-1');

      final deletion = newStore.delete();
      platform.releaseValue('draft-1');
      await Future.wait([saving, deletion]);
      expect((await platform.getAll()).containsKey(storageKey), isFalse);
      expect(await newStore.load(), isNull);

      // A new launch reads the platform store, not the old in-memory cache.
      SharedPreferences.resetStatic();
      final afterRestart = await WorkoutDraftStore(owner).load();
      expect(
        afterRestart,
        isNull,
        reason:
            'the save from the first store completed after delete and '
            'resurrected draft-1 on disk',
      );
    },
  );

  test('finish cleanup from the first ride must not erase the second ride checkpoint', () async {
    final firstRideStore = WorkoutDraftStore(owner);
    final secondRideStore = WorkoutDraftStore(owner);
    platform.blockValueContaining('draft-1');

    final firstRideSave = firstRideStore.save(draft('draft-1'));
    await platform.waitForEntered('draft-1');

    // Finish of the first ride queues its cleanup behind the delayed save,
    // then a new ride starts on a fresh store instance.
    final firstRideDelete = firstRideStore.delete();
    final secondSave = secondRideStore.save(draft('draft-2'));
    platform.releaseValue('draft-1');
    await Future.wait([firstRideSave, firstRideDelete, secondSave]);
    expect((await platform.getAll())[storageKey], contains('draft-2'));
    // Even operations submitted by the old controller after the new save
    // must not overwrite or delete the current checkpoint.
    await firstRideStore.save(draft('draft-1'));
    await firstRideStore.delete();

    SharedPreferences.resetStatic();
    final afterRestart = await WorkoutDraftStore(owner).load();
    expect(
      afterRestart?.localId,
      'draft-2',
      reason:
          'late save/delete from the finished first ride removed the '
          'checkpoint of the active second ride',
    );
  });
  test(
    'an unused old controller cannot claim a lease after a newer writer',
    () async {
      final old = WorkoutDraftStore(owner);
      final current = WorkoutDraftStore(owner);
      await current.save(draft('draft-2'));
      await old.save(draft('draft-1'));
      await old.delete();
      SharedPreferences.resetStatic();
      expect((await WorkoutDraftStore(owner).load())?.localId, 'draft-2');
    },
  );

  test('a blocked account does not block another account', () async {
    final blocked = WorkoutDraftStore(owner);
    platform.blockValueContaining('draft-1');
    final saving = blocked.save(draft('draft-1'));
    await platform.waitForEntered('draft-1');
    try {
      expect(await WorkoutDraftStore('another-account').load(), isNull);
    } finally {
      platform.releaseValue('draft-1');
      await saving;
    }
  });
}
