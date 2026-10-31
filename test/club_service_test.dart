import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/services/club_service.dart';
import 'package:pulsepath/services/group_ride_service.dart';
import 'package:pulsepath/services/group_workout_navigation.dart';
import 'package:pulsepath/config/app_variant.dart';

import 'group_coordination_test.dart' show me, other, snapshot;

void main() {
  late SupabaseClient client;
  late Future<http.Response> Function(http.Request) handle;
  late http.Request request;
  http.Response json(Object? data, {int status = 200}) => http.Response(
    jsonEncode(data),
    status,
    headers: {'content-type': 'application/json'},
    request: request,
  );
  setUp(() async {
    handle = (_) async => json([]);
    client = SupabaseClient(
      'https://club-service.example.invalid',
      'test-only',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        request = r;
        if (r.url.path.endsWith('/token')) {
          String part(Object data) => base64Url
              .encode(utf8.encode(jsonEncode(data)))
              .replaceAll('=', '');
          return json({
            'access_token':
                '${part({'alg': 'HS256'})}.${part({'sub': me, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.signature',
            'refresh_token': 'fake',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': me,
              'aud': 'authenticated',
              'role': 'authenticated',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-10-31T00:00:00Z',
            },
          });
        }
        if (r.url.path.endsWith('/logout')) return json({});
        return handle(r);
      }),
    );
    await client.auth.signInWithPassword(
      email: 'qa@example.invalid',
      password: 'test-only',
    );
  });
  tearDown(() async {
    GroupWorkoutNavigation.instance.consume();
    await client.dispose();
  });
  test(
    'club request sends only the intended action, club and payload',
    () async {
      Map? payload;
      handle = (r) async {
        payload = jsonDecode(r.body) as Map;
        return json({'id': 'club', 'member': true});
      };
      final result = await ClubService(client: client).action(
        'event_attend',
        club: 'club',
        data: {'id': 'event', 'attending': true},
      );
      expect(result['member'], true);
      expect(payload, {
        'p_action': 'event_attend',
        'p_club': 'club',
        'p_data': {'id': 'event', 'attending': true},
      });
    },
  );
  test(
    'membership revocation is terminal, network failure is retryable',
    () async {
      final service = ClubService(client: client);
      handle = (_) async => json({
        'code': 'P0001',
        'message': 'CLUB_MEMBER_REQUIRED',
      }, status: 400);
      await expectLater(
        service.snapshot('club'),
        throwsA(
          isA<ClubException>().having((e) => e.accessLost, 'lost access', true),
        ),
      );
      handle = (_) async => throw http.ClientException('offline');
      await expectLater(
        service.snapshot('club'),
        throwsA(
          isA<ClubException>().having((e) => e.accessLost, 'can retry', false),
        ),
      );
    },
  );
  test('late club response cannot appear after logout', () async {
    final entered = Completer<void>(), response = Completer<http.Response>();
    handle = (_) async {
      if (!entered.isCompleted) entered.complete();
      return response.future;
    };
    final pending = ClubService(client: client).home();
    final expectation = expectLater(
      pending,
      throwsA(
        isA<ClubException>().having((e) => e.accessLost, 'account scope', true),
      ),
    );
    await entered.future;
    await client.auth.signOut(scope: SignOutScope.local);
    response.complete(
      json([
        {'id': 'private-club'},
      ]),
    );
    await expectation;
  });
  test(
    'organizer is brought to preparation exactly once when an invitee joins',
    () async {
      bool accepted = false;
      handle = (r) async {
        if (r.url.path.endsWith('/group_invite_send'))
          return json({'id': 'invite', 'sender_id': me, 'receiver_id': other});
        if (r.url.path.endsWith('/group_room_snapshot_v2')) {
          final row = snapshot();
          if (!accepted)
            row['members'] = (row['members'] as List)
                .where((m) => m['user_id'] == me)
                .toList();
          return json(row);
        }
        throw StateError('Unexpected request');
      };
      final service = GroupRideService.forTesting(client: client);
      await service.restoreSession();
      await service.sendInvitation(other, 'invite');
      expect(GroupWorkoutNavigation.instance.roomId, isNull);
      accepted = true;
      await service.refreshMembers();
      expect(GroupWorkoutNavigation.instance.roomId, service.activeRoomId);
      expect(GroupWorkoutNavigation.instance.userId, me);
      GroupWorkoutNavigation.instance.consume();
      await service.refreshMembers();
      expect(GroupWorkoutNavigation.instance.roomId, isNull);
      service.clearSession();
      service.dispose();
    },
    skip: !AppVariant.uiBeta,
  );
}
