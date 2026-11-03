import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/services/community_service.dart';
import 'package:pulsepath/models/community_post.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const me = '00000000-0000-4000-8000-000000000001';
  final requests = <http.Request>[];
  var changeDuringUpload = false;
  late Directory temp;
  late String photo;
  http.Response response(Object value) => http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json'},
    request: requests.last,
  );
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('community-privacy-test');
    photo = '${temp.path}/photo.jpg';
    await File(photo).writeAsBytes([255, 216, 255, 217]);
    await Supabase.initialize(
      url: 'https://privacy.example.invalid',
      publishableKey: 'test-only',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/token')) {
          String part(Object value) => base64Url
              .encode(utf8.encode(jsonEncode(value)))
              .replaceAll('=', '');
          return response({
            'access_token':
                '${part({'alg': 'HS256'})}.${part({'sub': me, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'fake',
            'user': {
              'id': me,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'test@example.invalid',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-01-01T00:00:00Z',
            },
          });
        }
        if (request.url.path.contains('/storage/v1/object/')) {
          if (changeDuringUpload && !request.url.path.contains('/sign/')) {
            changeDuringUpload = false;
            await Supabase.instance.client.auth.signOut(
              scope: SignOutScope.local,
            );
          }
          if (request.url.path.contains('/sign/'))
            return response({
              'signedURL':
                  '${request.url.path.replaceFirst('/storage/v1', '')}?token=test',
            });
          return response({'Key': 'test'});
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/community_posts'))
          return response({'audience': 'friends'});
        if (request.method == 'POST')
          return http.Response('', 201, request: request);
        return response([]);
      }),
    );
  });
  setUp(() async {
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'test@example.invalid',
      password: 'test-only',
    );
    requests.clear();
    changeDuringUpload = false;
  });
  tearDownAll(() async {
    await Supabase.instance
        .dispose(); /* Preserve test artifacts under user no-delete rule. */
  });
  test('stale expected account cannot publish or upload', () async {
    final service = CommunityService();
    await expectLater(
      service.createPost('draft', expectedOwner: 'other'),
      throwsA(isA<CommunityServiceException>()),
    );
    await expectLater(
      service.uploadPhoto(photo, expectedOwner: 'other'),
      throwsA(isA<CommunityServiceException>()),
    );
    expect(
      requests.where(
        (r) =>
            r.url.path.contains('/storage/') ||
            r.url.path.endsWith('/community_posts'),
      ),
      isEmpty,
    );
  });
  test('concurrent photos use unique paths without overwrite', () async {
    final urls = await Future.wait([
      CommunityService().uploadPhoto(photo),
      CommunityService().uploadPhoto(photo),
    ]);
    expect(urls.toSet().length, 2);
    final uploads = requests.where(
      (r) => r.url.path.contains('/storage/v1/object/'),
    );
    expect(uploads.map((r) => r.url.path).toSet().length, 2);
    expect(uploads.every((r) => r.headers['x-upsert'] != 'true'), isTrue);
  });
  test('account change during upload stops post insertion', () async {
    changeDuringUpload = true;
    await expectLater(
      CommunityService().createPost(
        'draft',
        photoPaths: [photo],
        expectedOwner: me,
      ),
      throwsA(isA<CommunityServiceException>()),
    );
    expect(
      requests.where(
        (r) => r.method == 'POST' && r.url.path.endsWith('/community_posts'),
      ),
      isEmpty,
    );
  });
  test('friends post and comment photos never use public bucket', () async {
    await CommunityService().createPost(
      'friends',
      photoPaths: [photo],
      audience: CommunityPostAudience.friends,
    );
    await CommunityService().addComment(
      'post',
      body: 'reply',
      photoPath: photo,
    );
    final uploads = requests.where(
      (r) => r.url.path.contains('/storage/v1/object/'),
    );
    expect(uploads.length, 2);
    expect(
      uploads.every((r) => r.url.path.contains('/community_private/')),
      isTrue,
    );
    final post = jsonDecode(
      requests
          .firstWhere(
            (r) =>
                r.method == 'POST' && r.url.path.endsWith('/community_posts'),
          )
          .body,
    ) as Map;
    expect(post['photo_urls'], isNull);
    expect(post['private_photo_paths'], hasLength(1));
    final comment = jsonDecode(
      requests
          .firstWhere(
            (r) => r.method == 'POST' && r.url.path.endsWith('/post_comments'),
          )
          .body,
    ) as Map;
    expect(comment['photo_url'], isNull);
    expect(comment['private_photo_path'], startsWith('$me/'));
  });
  test('private refs survive snapshots while signed URLs do not', () async {
    final p = CommunityPost(
      id: 'post',
      authorId: me,
      authorName: 'A',
      body: 'x',
      likeCount: 0,
      likedByMe: false,
      createdAt: DateTime(2026),
      audience: CommunityPostAudience.friends,
      privatePhotoPaths: const ['$me/test.jpg'],
    );
    final hydrated = await CommunityService().resolvePostMedia(
      p,
      expectedOwner: me,
    );
    expect(hydrated.photoUrls, hasLength(1));
    final snapshot = hydrated.toSnapshot();
    expect(snapshot['photoUrls'], isEmpty);
    final restored = CommunityPost.fromSnapshot(snapshot);
    expect(restored.audience, CommunityPostAudience.friends);
    expect(restored.privatePhotoPaths, p.privatePhotoPaths);
  });
  test(
    'video uses private bucket, signed runtime URL and no signed cache',
    () async {
      final video = '${temp.path}/video.mp4';
      await File(video).writeAsBytes([0, 0, 0, 24]);
      await CommunityService().createPost(
        '',
        videoPath: video,
        topics: ['travel', 'memes', 'travel', 'unknown'],
      );
      final upload = requests.firstWhere(
        (r) => r.url.path.contains('/community_videos/'),
      );
      expect(upload.headers['x-upsert'], isNot('true'));
      final row = jsonDecode(
        requests
            .firstWhere(
              (r) =>
                  r.method == 'POST' && r.url.path.endsWith('/community_posts'),
            )
            .body,
      ) as Map;
      expect(row['video_path'], startsWith('$me/video_'));
      expect(row['topics'], ['travel', 'memes']);
      final post = CommunityPost(
        id: 'p',
        authorId: me,
        authorName: 'A',
        body: '',
        likeCount: 0,
        likedByMe: false,
        createdAt: DateTime(2026),
        videoPath: row['video_path'] as String,
        topics: ['travel'],
      );
      final resolved = await CommunityService().resolvePostMedia(post);
      expect(resolved.videoUrl, contains('/object/sign/community_videos/'));
      final restored = CommunityPost.fromSnapshot(resolved.toSnapshot());
      expect(restored.videoUrl, isNull);
      expect(restored.videoPath, post.videoPath);
      expect(restored.topics, ['travel']);
    },
  );
  test('changed account during video upload prevents post insertion', () async {
    final video = '${temp.path}/video-switch.mp4';
    await File(video).writeAsBytes([0, 0, 0, 24]);
    changeDuringUpload = true;
    await expectLater(
      CommunityService().createPost('', videoPath: video),
      throwsA(isA<CommunityServiceException>()),
    );
    expect(
      requests.where(
        (r) => r.method == 'POST' && r.url.path.endsWith('/community_posts'),
      ),
      isEmpty,
    );
  });
  test('unsupported video format fails before network upload', () async {
    await expectLater(
      CommunityService().uploadVideo(photo),
      throwsA(isA<CommunityServiceException>()),
    );
    expect(requests, isEmpty);
  });
  test('oversized video is rejected before Storage writes', () async {
    final video = File('${temp.path}/oversize.mp4');
    final handle = await video.open(mode: FileMode.write);
    await handle.truncate(CommunityService.maxVideoBytes + 1);
    await handle.close();
    await expectLater(
      CommunityService().uploadVideo(video.path),
      throwsA(isA<CommunityServiceException>()),
    );
    expect(requests, isEmpty);
  });
}
