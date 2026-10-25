import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/data/progress_goals_repository.dart';
import 'package:pulsepath/models/progress_period.dart';
import 'package:pulsepath/services/community_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const me = '00000000-0000-4000-8000-000000000001';
  const friend = '00000000-0000-4000-8000-000000000002';
  const postId = '00000000-0000-4000-8000-000000000003';
  final requests = <http.Request>[];
  var offline = false;
  var remoteGoal = 50.0;
  var returnDeleted = false;
  http.Response response(Object body, http.Request request, {int code = 200}) =>
      http.Response(
        jsonEncode(body),
        code,
        headers: {'content-type': 'application/json'},
        request: request,
      );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://community-test.example.invalid',
      publishableKey: 'test-only',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path.endsWith('/token')) {
          final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
          String part(Object v) =>
              base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
          return response({
            'access_token':
                '${part({'alg': 'HS256'})}.${part({'sub': me, 'exp': exp})}.signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'test-only',
            'user': {
              'id': me,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'test@example.invalid',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-01-01T00:00:00Z',
            },
          }, request);
        }
        if (offline)
          return response(
            {'message': 'offline', 'code': '503'},
            request,
            code: 503,
          );
        if (path.endsWith('/friends'))
          return response([
            {'friend_id': friend},
          ], request);
        if (path.endsWith('/public_profiles'))
          return response([
            {'id': friend, 'username': 'Друг'},
          ], request);
        if (path.endsWith('/community_posts')) {
          if (request.method == 'DELETE')
            return response(
              returnDeleted
                  ? [
                      {'id': postId},
                    ]
                  : [],
              request,
            );
          if (request.method == 'POST') return response([], request, code: 201);
          return response([
            {
              'id': postId,
              'author_id': friend,
              'body': 'Вечерний круг',
              'created_at': '2026-10-19T10:00:00Z',
            },
          ], request);
        }
        if (path.endsWith('/goals')) {
          if (request.method == 'POST') {
            remoteGoal = (jsonDecode(request.body)['goal_km'] as num)
                .toDouble();
            return response([], request, code: 201);
          }
          return response([
            {'period': 'week', 'goal_km': remoteGoal},
          ], request);
        }
        return response([], request);
      }),
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'test@example.invalid',
      password: 'test-only',
    );
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
  });
  setUp(() {
    requests.clear();
    offline = false;
    returnDeleted = false;
  });

  test(
    'Friends feed filters on the server and uses a stable two-column cursor',
    () async {
      final posts = await CommunityService().fetchFeed(
        scope: CommunityFeedScope.friends,
        before: DateTime.utc(2026, 10, 19, 10),
        beforeId: postId,
        limit: 20,
        strict: true,
      );
      expect(posts.single.authorName, 'Друг');
      final query = requests
          .firstWhere((r) => r.url.path.endsWith('/community_posts'))
          .url
          .queryParameters;
      expect(query['author_id'], 'in.("$friend")');
      expect(query['order'], 'created_at.desc.nullslast,id.desc.nullslast');
      expect(query['limit'], '20');
      expect(query['or'], contains('created_at.lt.2026-10-19T10:00:00.000Z'));
      expect(query['or'], contains('id.lt.$postId'));
    },
  );

  test('Own posts are filtered before pagination and malformed cursors never reach the API', () async {
    await CommunityService().fetchFeed(
      scope: CommunityFeedScope.mine,
      strict: true,
    );
    expect(
      requests
          .firstWhere((r) => r.url.path.endsWith('/community_posts'))
          .url
          .queryParameters['author_id'],
      'eq.$me',
    );
    requests.clear();
    await expectLater(
      CommunityService().fetchFeed(
        before: DateTime.now(),
        beforeId: 'bad,or',
        strict: true,
      ),
      throwsA(isA<CommunityServiceException>()),
    );
    expect(requests, isEmpty);
  });

  test('Failed likes and denied deletion return actionable errors rather than false success', () async {
    await expectLater(
      CommunityService().deletePost(postId),
      throwsA(isA<CommunityServiceException>()),
    );
    final request = requests.last;
    expect(request.url.queryParameters['author_id'], 'eq.$me');
    returnDeleted = true;
    await CommunityService().deletePost(postId);
    offline = true;
    await expectLater(
      CommunityService().toggleLike(postId, isLiked: false),
      throwsA(isA<CommunityServiceException>()),
    );
  });

  test('An offline weekly goal survives an older cloud value and is resent on reconnect', () async {
    final repo = ProgressGoalsRepository();
    offline = true;
    await repo.setGoal(ProgressPeriod.week, 225);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('progress_goal_pending_week_$me'), isTrue);
    offline = false;
    await repo.load();
    expect(repo.goalFor(ProgressPeriod.week), 225);
    expect(remoteGoal, 225);
    expect(prefs.getDouble('progress_goal_week_$me'), 225);
    expect(prefs.getBool('progress_goal_pending_week_$me'), isNull);
  });
}
