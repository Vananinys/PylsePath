// Characterization test from the head audit of 2026-11-15.
//
// Pins the CURRENT behavior of a real production class; a green run does NOT
// mean the behavior is correct — it documents the deliberate trade-off in
// _isSameRide (AUDIT_HEAD_NOTES_RU.md, FINDING B). Legacy deduplication is
// out of scope for the GPX limits fix and must not be changed silently.
//
// The GPX findings (A/A2) from that audit are fixed on this branch; their
// replacements live in gpx_import_limits_test.dart.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/saved_route.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'FINDING B: cloud restore drops a distinct ride that starts within 60 s '
    'and 10 m of a legacy synced row',
    () async {
      // Legacy rows synced before remote ids existed have remoteId == null
      // and cloudSynced == true. WorkoutHistoryRepository._isSameRide then
      // treats ANY remote row within 60 s start-time and 0.01 km distance as
      // the same ride, so mergeRemote skips it — a genuinely different ride
      // never reaches history and is not re-downloaded later.
      final legacy = SavedRoute(
        localId: 'legacy-a',
        title: 'legacy-a',
        distance: '1.00 км',
        duration: '5 мин',
        surfaceSummary: '',
        finishPoint: const LatLng(55, 83),
        routePoints: const [LatLng(55, 83)],
        activityType: ActivityType.cycling,
        cloudSynced: true,
        remoteId: null,
        createdAt: DateTime.utc(2026, 11, 15, 9),
      );
      final distinct = SavedRoute(
        localId: 'distinct-b',
        title: 'distinct-b',
        distance: '1.004 км',
        duration: '5 мин',
        surfaceSummary: '',
        finishPoint: const LatLng(55, 83.01),
        routePoints: const [LatLng(55, 83.01)],
        activityType: ActivityType.cycling,
        cloudSynced: true,
        remoteId: 'remote-b',
        createdAt: DateTime.utc(2026, 11, 15, 9, 0, 30),
      );
      final cloudCopy = SavedRoute(
        localId: 'remote-copy',
        title: 'remote-copy',
        distance: '1.00 км',
        duration: '5 мин',
        surfaceSummary: '',
        finishPoint: const LatLng(55, 83),
        routePoints: const [LatLng(55, 83)],
        activityType: ActivityType.cycling,
        cloudSynced: true,
        remoteId: 'remote-a',
        createdAt: DateTime.utc(2026, 11, 15, 9),
      );

      final repo = WorkoutHistoryRepository();
      await repo.addWorkout(legacy);
      await repo.mergeRemote([cloudCopy, distinct]);

      // Actual behavior: the distinct ride is silently missing from history;
      // later restore attempts cannot bring it back while the fuzzy window
      // matches.
      expect(
        repo.workoutHistory.map((r) => r.localId),
        ['legacy-a'],
        reason: 'remote-b is dropped by the legacy fuzzy-match window',
      );
      final persisted = await SharedPreferences.getInstance();
      final envelope =
          jsonDecode(persisted.getString('workout_history_guest')!) as Map;
      expect((envelope['workouts'] as List), hasLength(1));
    },
  );
}
