// Forward compatibility of the unfinished-ride checkpoint.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/data/workout_draft_store.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../deepseek_integrity/network_guard.dart';
import 'qa_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(NetworkGuard.install);
  tearDownAll(NetworkGuard.restore);

  const owner = 'draft-owner';
  const draftKey = 'workout_draft_$owner';

  late QaPreferencesStore platform;
  late SharedPreferencesStorePlatform previousPlatform;

  setUp(() {
    previousPlatform = SharedPreferencesStorePlatform.instance;
    platform = QaPreferencesStore();
    SharedPreferencesStorePlatform.instance = platform;
    SharedPreferences.resetStatic();
  });

  tearDown(() {
    SharedPreferencesStorePlatform.instance = previousPlatform;
    SharedPreferences.resetStatic();
  });

  Future<Object?> durable(String key) async =>
      (await platform.getAll())['flutter.$key'];

  WorkoutDraft draft(String id) => WorkoutDraft(
    ownerId: owner,
    localId: id,
    startedAt: DateTime.utc(2026, 10, 28, 8),
    activeMilliseconds: 60000,
    distanceMeters: 1000,
    elevationGainMeters: 3,
    activity: ActivityType.cycling,
    path: const [LatLng(55, 83), LatLng(55.001, 83.001)],
  );

  test('a future draft version is refused and archived verbatim before replacement', () async {
    final store = await SharedPreferences.getInstance();
    final future = jsonEncode({
      'version': 2,
      'ownerId': owner,
      'localId': 'future-draft',
      'startedAt': '2026-10-28T08:00:00.000Z',
      'activeMilliseconds': 1000,
      'distanceMeters': 10,
      'elevationGainMeters': 1,
      'activity': 'cycling',
      'path': [
        [55.0, 83.0],
      ],
      'weather_v2': {'temp_c': 7},
    });
    await store.setString(draftKey, future);

    await expectLater(WorkoutDraftStore(owner).load(), throwsFormatException);
    final backupKey =
        '${draftKey}_damaged_${sha256.convert(utf8.encode(future))}';
    expect(await durable(backupKey), future);
    expect(await durable(draftKey), future);

    await WorkoutDraftStore(owner).save(draft('new-draft'));
    expect(await durable(backupKey), future);
    expect(await durable(draftKey), contains('new-draft'));

    SharedPreferences.resetStatic();
    final reopened = await WorkoutDraftStore(owner).load();
    expect(reopened?.localId, 'new-draft');
    expect(reopened?.path, hasLength(2));
  });
}
