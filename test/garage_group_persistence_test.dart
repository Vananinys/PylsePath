import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/saved_route.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/services/garage_service.dart';
import 'package:pulsepath/services/group_ride_service.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/data/account_progress_cache.dart';

// All HTTP is intercepted; these regressions never access real user data.
const me = '00000000-0000-4000-8000-000000000001';
const bikeA = '00000000-0000-4000-8000-000000000002';
const bikeB = '00000000-0000-4000-8000-000000000003';
const room = '00000000-0000-4000-8000-000000000010';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  bool garageOffline = false,
      rejectPhotoUpdate = false,
      deletedPhoto = false,
      rejectProgress = false;
  Completer<void>? activeGate, activeStarted, rideGate, rideStarted;
  var serverState = 'active';
  var serverMeters = 100.0;
  var serverSeconds = 20;
  final progressRequests = <Map<String, dynamic>>[];
  Map<String, dynamic> bike(String id, bool active) => {
    'id': id,
    'user_id': me,
    'title': id == bikeA ? 'Audit A' : 'Audit B',
    'type': 'roadCycling',
    'is_active': active,
    'weight_kg': 9,
    'total_distance': 100,
    'created_at': '2026-11-14T00:00:00Z',
  };
  Map<String, dynamic> snapshot() => {
    'room': {
      'id': room,
      'code': 'ABCDEF123456',
      'title': 'Audit room',
      'host_id': me,
      'members': [
        {
          'user_id': me,
          'profile': {'username': 'Synthetic'},
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'workout_state': serverState,
          'distance_m': serverMeters,
          'duration_seconds': serverSeconds,
        },
      ],
    },
    'invitations': [],
  };
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://audit.example.invalid',
      publishableKey: 'synthetic-only',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((r) async {
        Object body = [];
        var status = 200;
        if (r.url.path.endsWith('/token')) {
          String part(Object x) =>
              base64Url.encode(utf8.encode(jsonEncode(x))).replaceAll('=', '');
          body = {
            'access_token':
                '${part({'alg': 'HS256'})}.${part({'sub': me, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.synthetic',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'synthetic',
            'user': {
              'id': me,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'audit@example.invalid',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-11-14T00:00:00Z',
            },
          };
        } else if (r.url.path.endsWith('/rides') && r.method == 'POST') {
          rideStarted?.complete();
          await rideGate?.future;
          body = {'id': (jsonDecode(r.body) as Map)['id']};
        } else if (r.url.path.endsWith('/garage')) {
          if (r.method == 'GET') {
            if (garageOffline) {
              status = 503;
              body = {'message': 'offline'};
            } else {
              body = [bike(bikeA, false), bike(bikeB, true)];
            }
          } else if (r.method == 'PATCH' && rejectPhotoUpdate) {
            status = 503;
            body = {'message': 'offline'};
          }
        } else if (r.url.path.contains('/object/list/')) {
          body = [
            {
              'name': '$bikeA.jpg',
              'id': 'synthetic',
              'created_at': '2026-11-14T00:00:00Z',
              'metadata': {},
            },
          ];
        } else if (r.url.path.contains('/object/') && r.method == 'DELETE') {
          deletedPhoto = true;
        } else if (r.url.path.endsWith('/group_ui_snapshot')) {
          body = snapshot();
        } else if (r.url.path.endsWith('/group_rides_members')) {
          final data = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
          progressRequests.add(data);
          if (rejectProgress) {
            status = 503;
            body = {'message': 'offline'};
          } else {
            if (data['workout_state'] == 'active' && activeGate != null) {
              activeStarted!.complete();
              await activeGate!.future;
            }
            serverState = data['workout_state'] as String;
            serverMeters = (data['distance_m'] as num).toDouble();
            serverSeconds = data['duration_seconds'] as int;
            body = [
              {'id': 'synthetic'},
            ];
          }
        }
        return http.Response(
          jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
          request: r,
        );
      }),
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'audit@example.invalid',
      password: 'synthetic',
    );
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
  });
  setUp(() async {
    garageOffline = false;
    rejectPhotoUpdate = false;
    deletedPhoto = false;
    rejectProgress = false;
    rideGate = null;
    rideStarted = null;
    activeGate = null;
    activeStarted = null;
    serverState = 'active';
    serverMeters = 100;
    serverSeconds = 20;
    progressRequests.clear();
    GarageService().bindToSession(null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('group_finished_room_$me');
    await prefs.remove('group_finish_outbox_v1_$me');
    await AccountProgressCache(
      'garage_rows',
      me,
    ).write([bike(bikeA, false), bike(bikeB, true)]);
  });
  test(
    'G1: successful active-bike choice survives an offline restart',
    () async {
      final service = GarageService();
      expect(await service.setActiveVehicle(bikeA), true);
      garageOffline = true;
      final restored = await GarageService().fetchActiveVehicle();
      expect(restored?.id, bikeA);
    },
  );
  test('G2: deleted vehicle stays absent from the offline cache', () async {
    final service = GarageService();
    await service.fetchVehicles();
    expect(await service.deleteVehicle(bikeA), true);
    expect(service.vehicles.any((v) => v.id == bikeA), false);
    garageOffline = true;
    expect((await service.fetchVehicles()).any((v) => v.id == bikeA), false);
  });
  test('G3: failed photo metadata update preserves stored photo', () async {
    rejectPhotoUpdate = true;
    final result = await GarageService().removeVehiclePhoto(bikeA);
    expect(result, false);
    expect(deletedPhoto, false);
  });
  test('J1: final progress is ordered after an older active request', () async {
    final group = GroupRideService.forTesting(
      client: Supabase.instance.client,
      uiFlow: true,
    );
    await group.refreshMembers();
    activeGate = Completer<void>();
    activeStarted = Completer<void>();
    final old = group.updateProgress(
      room,
      distanceMeters: 100,
      durationSeconds: 20,
      workoutState: 'active',
    );
    await activeStarted!.future;
    final finish = group.finishPersonalWorkout(room, 500, 60);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    activeGate!.complete();
    await old;
    await finish;
    expect(serverState, 'finished');
    expect(serverMeters, 500);
    await group.updateProgress(
      room,
      distanceMeters: 100,
      durationSeconds: 20,
      workoutState: 'active',
    );
    expect(serverState, 'finished');
    expect(group.finishPending, false);
    group.dispose();
  });
  test('J2: failed final progress is restored and acknowledged after controller restart', () async {
    final first = GroupRideService.forTesting(
      client: Supabase.instance.client,
      uiFlow: true,
    );
    await first.refreshMembers();
    rejectProgress = true;
    await first.finishPersonalWorkout(room, 500, 60);
    expect(first.error, isNotNull);
    expect(first.ownFinished, true);
    first.dispose();
    rejectProgress = false;
    final restored = GroupRideService.forTesting(
      client: Supabase.instance.client,
      uiFlow: true,
    );
    await restored.refreshMembers();
    expect(restored.ownFinished, true);
    final controller = MapNavigationController(groupRideService: restored);
    await controller.publishGroupProgressForTesting();
    expect(progressRequests.last['workout_state'], 'finished');
    expect(progressRequests.last['distance_m'], 500);
    expect(progressRequests.last['duration_seconds'], 60);
    expect(restored.finishPending, false);
    expect(
      jsonDecode(
        (await SharedPreferences.getInstance()).getString(
          'group_finish_outbox_v1_$me',
        )!,
      ),
      isEmpty,
    );
    controller.dispose();
    restored.dispose();
  });
  test(
    'Local history stays writable while an upload is waiting for the server',
    () async {
      WorkoutHistoryRepository.resetInstancesForTesting();
      final history = WorkoutHistoryRepository();
      history.captureProgressForTesting = (_) async {};
      SavedRoute ride(String id) => SavedRoute.fromJson({
        'localId': id,
        'title': 'Synthetic workout',
        'distance': '1 km',
        'duration': '1 min',
        'surfaceSummary': '',
        'finishLat': 56.0,
        'finishLon': 85.0,
        'routePoints': [
          [56.0, 85.0],
        ],
      });
      await history.addWorkout(ride('upload-held'));
      rideGate = Completer<void>();
      rideStarted = Completer<void>();
      final retry = history.retryUnsynced(maxItems: 1);
      await rideStarted!.future;
      try {
        await history
            .addWorkout(ride('saved-offline'))
            .timeout(const Duration(seconds: 1));
        expect(
          history.workoutHistory.any((r) => r.localId == 'saved-offline'),
          true,
        );
      } finally {
        rideGate!.complete();
        await retry;
        rideGate = null;
        rideStarted = null;
      }
    },
  );
  for (final removeDuringUpload in [false, true]) {
    test(
      'Late upload preserves a concurrent ${removeDuringUpload ? 'delete' : 'edit'}',
      () async {
        SharedPreferences.setMockInitialValues({});
        WorkoutHistoryRepository.resetInstancesForTesting();
        final history = WorkoutHistoryRepository();
        history.captureProgressForTesting = (_) async {};
        final original = SavedRoute.fromJson({
          'localId': 'concurrent-row',
          'title': 'Before upload',
          'distance': '1 km',
          'duration': '1 min',
          'surfaceSummary': '',
          'finishLat': 56.0,
          'finishLon': 85.0,
          'routePoints': [
            [56.0, 85.0],
          ],
        });
        await history.addWorkout(original);
        rideGate = Completer<void>();
        rideStarted = Completer<void>();
        final retry = history.retryUnsynced(maxItems: 1);
        await rideStarted!.future;
        try {
          if (removeDuringUpload) {
            await history
                .removeWorkout(original)
                .timeout(const Duration(seconds: 1));
          } else {
            final edited = SavedRoute.fromJson({
              ...original.toJson(),
              'title': 'Edited locally',
            });
            await history
                .replaceRoute(original, edited)
                .timeout(const Duration(seconds: 1));
          }
        } finally {
          rideGate!.complete();
          await retry;
          rideGate = null;
          rideStarted = null;
        }
        if (removeDuringUpload) {
          expect(history.workoutHistory, isEmpty);
          expect(history.hasPendingSync, true);
          await history.retryUnsynced(maxItems: 1);
          expect(history.workoutHistory, isEmpty);
          expect(history.hasPendingSync, false);
        } else {
          expect(history.workoutHistory.single.title, 'Edited locally');
          expect(history.workoutHistory.single.cloudSynced, false);
        }
      },
    );
  }
}
