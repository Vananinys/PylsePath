import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/data/workout_draft_store.dart';
import 'package:pulsepath/models/activity_type.dart';

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
}
