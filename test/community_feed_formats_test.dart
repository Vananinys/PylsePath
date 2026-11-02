import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/services/community_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = '00000000-0000-4000-8000-000000000001';
  const postId = '00000000-0000-4000-8000-000000000003';
  final requests = <http.Request>[];
  var hasAttachment = false;
  var inaccessible = false;
  http.Response response(Object value, http.Request request) => http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json'},
    request: request,
  );
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://formats-test.example.invalid',
      publishableKey: 'test-only',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/token')) {
          final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
          String part(Object value) => base64Url
              .encode(utf8.encode(jsonEncode(value)))
              .replaceAll('=', '');
          return response({
            'access_token':
                '${part({'alg': 'HS256'})}.${part({'sub': owner, 'exp': exp})}.signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'fake',
            'user': {
              'id': owner,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'test@example.invalid',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-01-01T00:00:00Z',
            },
          }, request);
        }
        if (request.url.path.endsWith('/community_posts')) {
          if (request.method == 'PATCH') {
            return response(
              inaccessible
                  ? []
                  : [
                      {'id': postId},
                    ],
              request,
            );
          }
          if (request.url.queryParameters['id'] != null) {
            return response(
              inaccessible
                  ? []
                  : [
                      {
                        'id': postId,
                        'author_id': owner,
                        'body': 'Original',
                        'audience': 'friends',
                        'private_photo_paths': hasAttachment
                            ? ['$owner/image.jpg']
                            : [],
                        'photo_urls': [],
                        'ride_id': null,
                        'route_attachment': null,
                      },
                    ],
              request,
            );
          }
        }
        return response([], request);
      }),
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'test@example.invalid',
      password: 'test-only',
    );
  });
  tearDownAll(() => Supabase.instance.dispose());
  setUp(() {
    requests.clear();
    hasAttachment = false;
    inaccessible = false;
  });
  for (final type in [CommunityPostType.photos, CommunityPostType.rides]) {
    test('$type retains both its content filter and stable cursor', () async {
      await CommunityService().fetchFeed(
        type: type,
        before: DateTime.utc(2026, 11, 2),
        beforeId: postId,
        strict: true,
      );
      final q = requests
          .firstWhere((r) => r.url.path.endsWith('/community_posts'))
          .url
          .queryParametersAll;
      final ors = q['or']!;
      expect(ors, hasLength(2));
      expect(
        ors.any(
          (v) => v.contains(
            type == CommunityPostType.photos
                ? 'private_photo_paths.not.eq.{}'
                : 'route_attachment.not.is.null',
          ),
        ),
        isTrue,
      );
      expect(
        ors.any(
          (v) =>
              v.contains('created_at.lt.2026-11-02T00:00:00.000Z') &&
              v.contains('id.lt.$postId'),
        ),
        isTrue,
      );
    });
  }
  test(
    'text filter excludes every attachment type while retaining its cursor',
    () async {
      await CommunityService().fetchFeed(
        type: CommunityPostType.text,
        before: DateTime.utc(2026, 11, 2),
        beforeId: postId,
        strict: true,
      );
      final q = requests
          .firstWhere((r) => r.url.path.endsWith('/community_posts'))
          .url
          .queryParametersAll;
      expect(q['ride_id'], ['is.null']);
      expect(q['route_attachment'], ['is.null']);
      expect(q['or'], hasLength(3));
      expect(
        q['or']!.any((v) => v.contains('photo_urls.is.null,photo_urls.eq.{}')),
        isTrue,
      );
      expect(
        q['or']!.any(
          (v) => v.contains(
            'private_photo_paths.is.null,private_photo_paths.eq.{}',
          ),
        ),
        isTrue,
      );
      expect(q['or']!.any((v) => v.contains('id.lt.$postId')), isTrue);
    },
  );
  test('editing patches only body with owner and post constraints', () async {
    hasAttachment = true;
    await CommunityService().updatePostBody(
      postId,
      ' Revised ',
      expectedOwner: owner,
    );
    final patch = requests.singleWhere((r) => r.method == 'PATCH');
    expect(jsonDecode(patch.body), {'body': 'Revised'});
    expect(patch.url.queryParameters['author_id'], 'eq.$owner');
    expect(patch.url.queryParameters['id'], 'eq.$postId');
    final read = requests.firstWhere((r) => r.method == 'GET');
    expect(read.url.queryParameters['author_id'], 'eq.$owner');
  });
  test(
    'empty text without an existing attachment never sends a patch',
    () async {
      await expectLater(
        CommunityService().updatePostBody(postId, '  ', expectedOwner: owner),
        throwsA(isA<CommunityServiceException>()),
      );
      expect(requests.where((r) => r.method == 'PATCH'), isEmpty);
    },
  );
  test('empty text preserves a post with an existing private photo', () async {
    hasAttachment = true;
    await CommunityService().updatePostBody(postId, '', expectedOwner: owner);
    expect(jsonDecode(requests.singleWhere((r) => r.method == 'PATCH').body), {
      'body': '',
    });
  });
  test('wrong account is rejected before any write or read', () async {
    await expectLater(
      CommunityService().updatePostBody(
        postId,
        'Changed',
        expectedOwner: 'another',
      ),
      throwsA(isA<CommunityServiceException>()),
    );
    expect(requests, isEmpty);
  });
  test('an inaccessible post cannot produce a successful edit', () async {
    inaccessible = true;
    await expectLater(
      CommunityService().updatePostBody(
        postId,
        'Changed',
        expectedOwner: owner,
      ),
      throwsA(isA<CommunityServiceException>()),
    );
    expect(requests.where((r) => r.method == 'PATCH'), isEmpty);
  });
}
