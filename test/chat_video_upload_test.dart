import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/services/chat_service.dart';
import 'package:pulsepath/services/ride_media_service.dart';
import 'package:pulsepath/data/ride_media_repository.dart';
import 'package:pulsepath/models/ride_media.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/video_metadata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const me = '00000000-0000-4000-8000-000000000001';
  const friend = '00000000-0000-4000-8000-000000000002';
  const id = '00000000-0000-4000-8000-000000000003';
  final requests = <http.Request>[];
  late Directory files;
  int uploadStatus = 200;
  bool signOutDuringLookup = false;
  setUpAll(() async {
    files = await Directory.systemTemp.createTemp('pulsepath-chat-video-test-');
    SharedPreferences.setMockInitialValues({});
    http.Response json(Object data, int status, http.Request request) =>
        http.Response(
          jsonEncode(data),
          status,
          headers: {'content-type': 'application/json'},
          request: request,
        );
    await Supabase.initialize(
      url: 'https://chat-video.example.invalid',
      publishableKey: 'test-only',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/token')) {
          String part(Object data) => base64Url
              .encode(utf8.encode(jsonEncode(data)))
              .replaceAll('=', '');
          return json(
            {
              'access_token':
                  '${part({'alg': 'HS256'})}.${part({'sub': me, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.signature',
              'refresh_token': 'fake-refresh',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': me,
                'aud': 'authenticated',
                'role': 'authenticated',
                'email': 'test@example.invalid',
                'app_metadata': {},
                'user_metadata': {},
                'created_at': '2026-10-26T00:00:00Z',
              },
            },
            200,
            request,
          );
        }
        if (request.url.path.endsWith('/logout')) return json({}, 200, request);
        if (request.url.path.contains('/object/sign/')) {
          return json(
            {'signedURL': '/object/sign/chat_media/private.mp4?token=test'},
            200,
            request,
          );
        }
        if (request.url.path.contains('/object/chat_media/') ||
            request.url.path.contains('/object/ride_media/')) {
          return uploadStatus == 409
              ? json(
                  {
                    'statusCode': '409',
                    'error': 'Duplicate',
                    'message': 'exists',
                  },
                  409,
                  request,
                )
              : json({'Key': 'chat_media/object'}, 200, request);
        }
        if (request.url.path.endsWith('/chat_messages')) {
          if (request.method == 'GET') {
            if (signOutDuringLookup) {
              await Supabase.instance.client.auth.signOut(
                scope: SignOutScope.local,
              );
            }
            return json([], 200, request);
          }
          return json(
            {
              ...jsonDecode(request.body) as Map<String, dynamic>,
              'created_at': '2026-10-26T00:00:00Z',
              'reactions': {},
            },
            201,
            request,
          );
        }
        throw StateError(
          'Unexpected request: ${request.method} ${request.url.path}',
        );
      }),
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'test@example.invalid',
      password: 'test',
    );
  });
  setUp(() {
    requests.clear();
    uploadStatus = 200;
  });
  tearDownAll(() async {
    ChatService().resetSession();
    await Supabase.instance.dispose();
  });
  Future<String> file(String name, List<int> bytes) async =>
      (await File('${files.path}/$name').writeAsBytes(bytes)).path;
  test(
    'Video goes to private bucket with correct MIME and persistent reference',
    () async {
      final path = await file('clip.mp4', [0, 0, 0, 20, 102, 116, 121, 112]);
      final saved = await ChatService().sendMessage(
        friend,
        messageId: id,
        videoPath: path,
      );
      final upload = requests.singleWhere(
        (r) => r.url.path.contains('/object/chat_media/'),
      );
      expect(upload.url.path, endsWith('/$me/chat_video_$id.mp4'));
      expect(upload.headers['content-type'], startsWith('multipart/form-data'));
      expect(
        latin1.decode(upload.bodyBytes).toLowerCase(),
        contains('content-type: video/mp4'),
      );
      final insert = requests.singleWhere(
        (r) => r.method == 'POST' && r.url.path.endsWith('/chat_messages'),
      );
      final row = jsonDecode(insert.body) as Map<String, dynamic>;
      expect(row['video_url'], 'chat:$me/chat_video_$id.mp4');
      expect(row['body'], 'Видео');
      expect(row.containsKey('photo_url'), isFalse);
      expect(saved!.isVideo, isTrue);
      expect(saved.videoReference, row['video_url']);
      expect(saved.toRow()['video_url'], row['video_url']);
      expect(
        saved.videoUrl,
        startsWith(
          'https://chat-video.example.invalid/storage/v1/object/sign/',
        ),
      );
    },
  );
  test('Poster uploads to private bucket, signs separately and preserves cache reference', () async {
    final video = await file('preview.mp4', [1, 2, 3]);
    final poster = await file('preview.jpg', [255, 216, 255, 217]);
    const metadata = VideoMetadata(
      width: 1920,
      height: 1080,
      durationMs: 10000,
      sizeBytes: 3,
    );
    final saved = await ChatService().sendMessage(
      friend,
      messageId: id,
      videoPath: video,
      videoPosterPath: poster,
      videoMetadata: metadata,
    );
    final uploads = requests
        .where((r) => r.url.path.contains('/object/chat_media/'))
        .toList();
    expect(uploads.length, 2);
    expect(uploads.last.url.path, endsWith('/$me/chat_poster_$id.jpg'));
    expect(latin1.decode(uploads.last.bodyBytes), contains('image/jpeg'));
    final insert = requests.singleWhere(
      (r) => r.method == 'POST' && r.url.path.endsWith('/chat_messages'),
    );
    final row = jsonDecode(insert.body) as Map<String, dynamic>;
    expect(row['video_poster_url'], 'chat:$me/chat_poster_$id.jpg');
    expect(row['video_metadata'], metadata.toJson());
    expect(saved!.videoPosterReference, row['video_poster_url']);
    expect(saved.toRow()['video_poster_url'], row['video_poster_url']);
    expect(saved.videoMetadata!.durationMs, 10000);
    expect(saved.videoPosterUrl, startsWith('https://'));
  });
  test(
    'Oversized poster rejected before allocating and uploading its bytes',
    () async {
      final video = await file('poster-large.mp4', [1, 2, 3]);
      final poster = File('${files.path}/poster-large.jpg');
      final handle = await poster.open(mode: FileMode.write);
      await handle.truncate(512 * 1024 + 1);
      await handle.close();
      await expectLater(
        ChatService().sendMessage(
          friend,
          messageId: id,
          videoPath: video,
          videoPosterPath: poster.path,
        ),
        throwsA(isA<ChatServiceException>()),
      );
      expect(
        requests.where((r) => r.url.path.contains('chat_poster_')),
        isEmpty,
      );
      expect(
        requests.where((r) => r.url.path.endsWith('/chat_messages')),
        isEmpty,
      );
    },
  );
  test(
    'Retry reuses object path and accepts an existing uploaded object',
    () async {
      uploadStatus = 409;
      final path = await file('retry.mov', [1, 2, 3]);
      final saved = await ChatService().sendMessage(
        friend,
        messageId: id,
        videoPath: path,
        retry: true,
      );
      expect(saved!.isVideo, isTrue);
      final upload = requests.singleWhere(
        (r) => r.url.path.contains('/object/chat_media/'),
      );
      expect(upload.url.path, endsWith('/$me/chat_video_$id.mov'));
      expect(
        latin1.decode(upload.bodyBytes).toLowerCase(),
        contains('content-type: video/quicktime'),
      );
    },
  );
  test(
    'Unsupported and empty video never reach storage or message insert',
    () async {
      await expectLater(
        ChatService().sendMessage(
          friend,
          messageId: id,
          videoPath: await file('bad.exe', [1, 2]),
        ),
        throwsA(isA<ChatServiceException>()),
      );
      await expectLater(
        ChatService().sendMessage(
          friend,
          messageId: id,
          videoPath: await file('empty.mp4', []),
        ),
        throwsA(isA<ChatServiceException>()),
      );
      expect(requests, isEmpty);
    },
  );
  SavedRoute mediaRoute(String localId) => SavedRoute(
    localId: localId,
    title: 'Ride',
    distance: '2 км',
    duration: '10 мин',
    surfaceSummary: '',
    activityType: ActivityType.cycling,
    routePoints: [for (var i = 0; i < 20; i++) LatLng(55 + i * .001, 37)],
    finishPoint: const LatLng(55.019, 37),
  );
  test('Hidden media never read missing local files or upload them', () async {
    final route = mediaRoute('hidden-media');
    await RideMediaRepository(route.localId).add([
      RideMedia(
        id: 'secret',
        pointIndex: 0,
        kind: RideMediaKind.video,
        localPath: '/missing/private.mov',
        createdAt: DateTime.utc(2026),
      ),
    ], pointCount: 20);
    final snapshot = await RideMediaService.prepareShare(
      route,
      selectedIds: {'secret'},
      hideRadiusMeters: 200,
    );
    expect(snapshot.media, isEmpty);
    expect(requests, isEmpty);
  });
  testWidgets('Only selected visible photo is uploaded to private ride_media', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 8, 4),
        Paint()..color = Colors.red,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(8, 4);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      final path = await file('visible.png', bytes);
      image.dispose();
      picture.dispose();
      final route = mediaRoute('visible-media');
      await RideMediaRepository(route.localId).add([
        RideMedia(
          id: 'visible',
          pointIndex: 10,
          kind: RideMediaKind.photo,
          localPath: path,
          createdAt: DateTime.utc(2026),
        ),
        RideMedia(
          id: 'hidden',
          pointIndex: 0,
          kind: RideMediaKind.photo,
          localPath: '/missing.png',
          createdAt: DateTime.utc(2026),
        ),
        RideMedia(
          id: 'not-selected',
          pointIndex: 11,
          kind: RideMediaKind.photo,
          localPath: '/missing2.png',
          createdAt: DateTime.utc(2026),
        ),
      ], pointCount: 20);
      final snapshot = await RideMediaService.prepareShare(
        route,
        selectedIds: {'visible', 'hidden'},
        hideRadiusMeters: 200,
      );
      expect(snapshot.media.map((m) => m.id), ['visible']);
      expect(
        snapshot.points[snapshot.media.single.pointIndex],
        route.routePoints[10],
      );
      final uploads = requests
          .where((r) => r.url.path.contains('/object/ride_media/'))
          .toList();
      expect(uploads.length, 1);
      expect(uploads.single.url.path, endsWith('/$me/visible.png'));
      expect(
        latin1.decode(uploads.single.bodyBytes).toLowerCase(),
        contains('content-type: image/png'),
      );
    });
  });
  test(
    'Account change during retry prevents upload of the previous account file',
    () async {
      signOutDuringLookup = true;
      await expectLater(
        ChatService().sendMessage(
          friend,
          messageId: id,
          retry: true,
          videoPath: await file('private.mp4', [1, 2, 3]),
        ),
        throwsA(isA<ChatServiceException>()),
      );
      expect(
        requests.any((r) => r.url.path.contains('/object/chat_media/')),
        isFalse,
      );
      expect(
        requests.any(
          (r) => r.method == 'POST' && r.url.path.endsWith('/chat_messages'),
        ),
        isFalse,
      );
    },
  );
  test(
    'Missing local voice file reports a file problem before upload',
    () async {
      signOutDuringLookup = false;
      await Supabase.instance.client.auth.signInWithPassword(
        email: 'test@example.invalid',
        password: 'test',
      );
      requests.clear();
      await expectLater(
        ChatService().sendMessage(
          friend,
          messageId: id,
          audioPath: '${files.path}/missing-voice.m4a',
          audioSeconds: 3,
        ),
        throwsA(
          isA<ChatServiceException>().having(
            (e) => e.message,
            'message',
            contains('недоступно'),
          ),
        ),
      );
      expect(
        requests.where((r) => r.url.path.contains('/object/chat_media/')),
        isEmpty,
      );
    },
  );
}
