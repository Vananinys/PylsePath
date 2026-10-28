import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:pulsepath/screens/profile_screen.dart';
import 'package:pulsepath/state/profile_provider.dart';
import 'package:pulsepath/services/profile_presentation_service.dart';
import 'package:pulsepath/widgets/profile_identity_card.dart';
import 'package:pulsepath/services/achievements_service.dart';
import 'package:pulsepath/data/profile_appearance_store.dart';

import 'package:pulsepath/services/legacy_progress_recovery.dart';
import 'package:pulsepath/services/owner_service.dart';
import 'package:pulsepath/data/account_progress_cache.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/activity_type.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = '00000000-0000-4000-8000-000000000001';
  final uploaded = <Map<String, dynamic>>[];
  var failing = false;
  var awardsOffline = false;
  var profileOffline = false;
  final awardRows = <Map<String, dynamic>>[];
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://offline-test.example.invalid',
      publishableKey: 'test-only',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((request) async {
        const headers = {'content-type': 'application/json'};
        if (request.url.path.endsWith('/token')) {
          String part(Object value) => base64Url
              .encode(utf8.encode(jsonEncode(value)))
              .replaceAll('=', '');
          final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
          return http.Response(
            jsonEncode({
              'access_token':
                  '${part({'alg': 'HS256'})}.${part({'sub': uid, 'exp': expiry})}.signature',
              'refresh_token': 'test-refresh',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': uid,
                'aud': 'authenticated',
                'role': 'authenticated',
                'email': 'test@example.invalid',
                'created_at': '2026-10-18T00:00:00Z',
                'app_metadata': {},
                'user_metadata': {},
              },
            }),
            200,
            headers: headers,
            request: request,
          );
        }
        if (profileOffline) {
          return http.Response(
            '{"message":"offline"}',
            503,
            headers: headers,
            request: request,
          );
        }
        if (request.url.path.endsWith('/rides') && request.method == 'POST') {
          final row = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          uploaded.add(row);
          return http.Response(
            failing ? '{"message":"offline"}' : jsonEncode({'id': row['id']}),
            failing ? 503 : 201,
            headers: headers,
            request: request,
          );
        }
        if (request.url.path.endsWith('/user_owner_awards')) {
          return http.Response(
            awardsOffline ? '{"message":"offline"}' : jsonEncode(awardRows),
            awardsOffline ? 503 : 200,
            headers: headers,
            request: request,
          );
        }
        return http.Response('[]', 200, headers: headers, request: request);
      }),
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'test@example.invalid',
      password: 'test-only',
    );
  });
  tearDownAll(() => Supabase.instance.dispose());
  setUp(() async {
    uploaded.clear();
    failing = false;
    awardsOffline = false;
    profileOffline = false;
    awardRows.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('workout_history_$uid');
    WorkoutHistoryRepository.resetInstancesForTesting();
  });
  SavedRoute ride(String id, {bool synced = false}) => SavedRoute(
    localId: id,
    title: id,
    distance: '1 км',
    duration: '5 мин',
    surfaceSummary: '',
    finishPoint: const LatLng(55, 83),
    routePoints: const [],
    activityType: ActivityType.cycling,
    cloudSynced: synced,
    createdAt: DateTime(2026, 10, 18),
  );

  testWidgets('customized profile is present on its very first visible frame', (
    tester,
  ) async {
    profileOffline = true;
    ProfilePresentationService.resetCachesForTesting();
    await AccountProgressCache('presentation', uid).write({
      'style': {
        'accent': 'violet',
        'cover': 'waves',
        'frame': 'double',
        'bio': 'Моё оформление',
      },
      'rewards': [],
    });
    final provider = ProfileProvider();
    await provider.ensureLocalLoaded();
    await tester.pumpWidget(
      MaterialApp(home: ProfileScreen(provider: provider)),
    );
    final card = tester.widget<ProfileIdentityCard>(
      find.byType(ProfileIdentityCard),
    );
    expect(card.style.accent, 'violet');
    expect(card.style.cover, 'waves');
    expect(card.style.frame, 'double');
    expect(card.style.bio, 'Моё оформление');
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    // Complete delayed HTTP retries/timeouts after the screen is gone.
    for (var cycle = 0; cycle < 5; cycle++) {
      await tester.pump(const Duration(seconds: 30));
    }
    provider.dispose();
  });

  test(
    'earned achievements restore from the latest appearance envelope offline',
    () async {
      await ProfileAppearanceStore(uid).stage({
        'style': {'accent': 'forest'},
        'rewards': [
          {
            'id': 'earned-example',
            'award_key': 'catalog:example',
            'kind': 'achievement',
            'label': 'Моя награда',
            'icon': '🏆',
            'equipped': false,
            'source': 'earned',
            'granted_at': '2026-10-24T00:00:00Z',
          },
        ],
      });
      await AchievementsService.restoreProgress();
      expect(AchievementsService.hasEarnedCatalog('example'), true);
    },
  );

  test(
    'previously uploaded rides are not sent again and ownership is preserved',
    () async {
      final repo = WorkoutHistoryRepository();
      await repo.addWorkout(ride('already-uploaded', synced: true));
      await repo.addWorkout(ride('pending'));
      expect(repo.hasPendingSync, isTrue);
      expect(await repo.retryUnsynced(), 1);
      expect(uploaded.map((r) => r['id']), ['pending']);
      expect(uploaded.single['user_id'], uid);
      expect(repo.hasPendingSync, isFalse);
      expect(await repo.retryUnsynced(), 0);
      expect(uploaded.length, 1);
    },
  );
  test('earned owner awards survive offline restart and confirmed revocations replace the cache', () async {
    awardRows.add({
      'id': '11111111-1111-4111-8111-111111111111',
      'kind': 'achievement',
      'award_key': 'builtin:Первый заезд',
      'label': 'Первый заезд',
      'icon': '🚲',
      'equipped': false,
      'granted_at': '2026-10-21T00:00:00Z',
    });
    expect((await OwnerService().awards()).length, 1);
    awardsOffline = true;
    expect((await OwnerService().awards()).single.label, 'Первый заезд');
    expect(
      await AccountProgressCache('owner_awards', 'another-account').read(),
      isNull,
    );
    awardsOffline = false;
    awardRows.clear();
    expect(await OwnerService().awards(), isEmpty);
    awardsOffline = true;
    expect(await OwnerService().awards(), isEmpty);
  });
  test('old unowned progress requires ownership confirmation and recovery is idempotent', () async {
    final prefs = await SharedPreferences.getInstance();
    final old = jsonEncode([ride('legacy-ride').toJson()]);
    await prefs.setString('workout_history', old);
    final recovery = LegacyProgressRecovery();
    await expectLater(
      recovery.recover(confirmedOwnership: false),
      throwsStateError,
    );
    expect(await recovery.recover(confirmedOwnership: true), 1);
    expect(await recovery.recover(confirmedOwnership: true), 0);
    final repository = WorkoutHistoryRepository();
    await repository.load();
    expect(
      repository.workoutHistory.where((r) => r.localId == 'legacy-ride').length,
      1,
    );
    expect(repository.hasPendingSync, true);
    expect(prefs.getString('workout_history'), old);
  });
  test(
    'batch limit leaves later rides durably queued for the next cycle',
    () async {
      final repo = WorkoutHistoryRepository();
      for (var i = 0; i < 4; i++) {
        await repo.addWorkout(ride('pending-$i'));
      }
      expect(await repo.retryUnsynced(maxItems: 2), 2);
      await repo.load();
      expect(repo.unsyncedWorkouts.length, 2);
      expect(await repo.retryUnsynced(maxItems: 2), 2);
      expect(uploaded.map((r) => r['id']).toSet().length, 4);
    },
  );
  test(
    'one failed upload stops a batch and reconnect retries the same stable id',
    () async {
      final repo = WorkoutHistoryRepository();
      for (var i = 0; i < 3; i++) {
        await repo.addWorkout(ride('pending-$i'));
      }
      failing = true;
      expect(await repo.retryUnsynced(), 0);
      expect(uploaded.length, 1);
      await repo.load();
      expect(repo.unsyncedWorkouts.length, 3);
      failing = false;
      expect(await repo.retryUnsynced(), 3);
      expect(uploaded[0]['id'], uploaded[1]['id']);
      expect(repo.hasPendingSync, isFalse);
    },
  );
  test(
    'A stale history repository cannot clear or save after logout',
    () async {
      final repository = WorkoutHistoryRepository();
      await repository.addWorkout(ride('owner-kept'));
      final prefs = await SharedPreferences.getInstance();
      final original = prefs.getString('workout_history_$uid');
      await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
      await expectLater(repository.clear(), throwsStateError);
      await expectLater(repository.save(), throwsStateError);
      await expectLater(
        repository.addWorkout(ride('stale-write')),
        throwsStateError,
      );
      expect(prefs.getString('workout_history_$uid'), original);
      await Supabase.instance.client.auth.signInWithPassword(
        email: 'test@example.invalid',
        password: 'test',
      );
    },
  );
}
