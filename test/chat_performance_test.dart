import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/services/chat_service.dart';
import 'package:pulsepath/services/notification_service.dart';
import 'package:pulsepath/data/chat_local_store.dart';
import 'package:pulsepath/models/chat_message.dart';
import 'package:pulsepath/widgets/chat_photo.dart';
import 'package:pulsepath/services/push_service.dart';
import 'package:pulsepath/data/app_image_cache.dart';

import 'dart:io';

// Synthetic account only; all HTTP and local-notification calls are intercepted.
// Push copy changes only imports, Windows support bridge and test access.
const me = '00000000-0000-4000-8000-000000000001';
const peer = '00000000-0000-4000-8000-000000000002';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <http.Request>[];
  Completer<void>? signingGate, signingStarted, initGate, initStarted;
  int shown = 0;
  bool photoRows = false;
  Map<String, dynamic> row(String id, {bool photo = false}) => {
    'id': id,
    'sender_id': peer,
    'receiver_id': me,
    'body': photo ? null : 'Synthetic text',
    'photo_url': photo ? 'chat:$peer/audit.jpg' : null,
    'created_at': '2026-11-14T00:00:00Z',
    'reactions': <String, dynamic>{},
  };
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final support = await Directory.systemTemp.createTemp('chat-performance-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => support.path,
        );
    await Supabase.initialize(
      url: 'https://audit.example.invalid',
      publishableKey: 'synthetic-only',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((r) async {
        requests.add(r);
        Object body = [];
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
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-11-14T00:00:00Z',
            },
          };
        } else if (r.url.path.endsWith('/rpc/chat_latest_for_friends')) {
          final ids = (jsonDecode(r.body) as Map)['friend_ids'] as List;
          body = ids
              .map(
                (id) => {
                  ...row('latest-' + id.toString(), photo: true),
                  'sender_id': id,
                },
              )
              .toList();
        } else if (r.url.path.contains('/object/sign/')) {
          if (signingGate != null) {
            if (!signingStarted!.isCompleted) signingStarted!.complete();
            await signingGate!.future;
          }
          body = r.url.path.endsWith('/chat_media')
              ? [
                  {
                    'path': '$peer/audit.jpg',
                    'signedURL':
                        '/object/sign/chat_media/$peer/audit.jpg?token=synthetic',
                  },
                ]
              : {
                  'signedURL':
                      '/object/sign/chat_media/$peer/audit.jpg?token=synthetic',
                };
        } else if (r.url.path.endsWith('/chat_messages')) {
          if (r.url.queryParameters['sender_id'] == 'eq.$me') {
            body = [];
          } else {
            body = r.url.queryParameters['limit'] == '1' && photoRows
                ? [row('photo', photo: true)]
                : [row('text'), if (photoRows) row('photo', photo: true)];
          }
        }
        return http.Response(
          jsonEncode(body),
          200,
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
    await AppImageCache.instance.dispose();
    await Supabase.instance.dispose();
  });
  setUp(() {
    requests.clear();
    shown = 0;
    photoRows = false;
    signingGate = null;
    signingStarted = null;
    initGate = null;
    initStarted = null;
    ChatService.openChatFriendId = null;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          (call) async {
            if (call.method == 'initialize') {
              initStarted?.complete();
              await initGate?.future;
              return true;
            }
            if (call.method == 'getNotificationAppLaunchDetails')
              return {'notificationLaunchedApp': false};
            if (call.method == 'show') shown++;
            return null;
          },
        );
  });
  tearDown(() {
    ChatService.openChatFriendId = null;
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'Opening a chat during notification initialization suppresses the alert',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final service = PushService.forTesting();
      initGate = Completer<void>();
      initStarted = Completer<void>();
      final message = ChatMessage.fromRow(row('notification-init'));
      final item = AppNotification(
        id: 'synthetic',
        type: AppNotificationType.chat,
        title: 'Synthetic',
        subtitle: 'Synthetic',
        createdAt: DateTime.now(),
        payloadUserId: peer,
      );
      final work = service.showIncomingChat(item, message);
      await initStarted!.future;
      ChatService.openChatFriendId = peer;
      initGate!.complete();
      await work;
      debugDefaultTargetPlatformOverride = null;
      expect(shown, 0);
    },
  );
  test(
    'Opening a chat during an unsuccessful preview suppresses the alert',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final service = PushService.forTesting();
      final started = Completer<void>(), release = Completer<void>();
      service.onChatPreview = (_) async {
        started.complete();
        await release.future;
        return false;
      };
      final work = service.handleForegroundForTesting(
        RemoteMessage(
          data: {
            'type': 'chat',
            'senderId': peer,
            'receiverId': me,
            'messageId': 'notification-preview',
          },
        ),
      );
      await started.future;
      ChatService.openChatFriendId = peer;
      release.complete();
      await work;
      debugDefaultTargetPlatformOverride = null;
      expect(shown, 0);
    },
  );
  test('Text page returns without waiting for Storage', () async {
    photoRows = true;
    signingGate = Completer<void>();
    signingStarted = Completer<void>();
    final messages = await ChatService.forTesting().fetchConversation(
      peer,
      strict: true,
      resolveAttachments: false,
    );
    expect(messages.any((m) => m.body == 'Synthetic text'), true);
    expect(
      requests.where((r) => r.url.path.contains('/object/sign/')),
      isEmpty,
    );
  });
  test('Reopening the same page reuses valid signed URLs', () async {
    photoRows = true;
    final service = ChatService.forTesting();
    await service.fetchConversation(peer, strict: true);
    await service.fetchConversation(peer, strict: true);
    expect(
      requests.where((r) => r.url.path.contains('/object/sign/')).length,
      1,
    );
    expect(
      requests.where((r) => r.url.path.endsWith('/chat_messages')).length,
      4,
    );
  });
  test('20 dialog previews use one RPC and no attachment signing', () async {
    final friends = List.generate(20, (i) => 'friend-$i');
    final result = await ChatService.forTesting().fetchLatestFor(friends);
    expect(result.length, 20);
    expect(
      requests
          .where((r) => r.url.path.endsWith('/rpc/chat_latest_for_friends'))
          .length,
      1,
    );
    expect(
      requests.where(
        (r) =>
            r.url.path.endsWith('/chat_messages') ||
            r.url.path.contains('/object/sign/'),
      ),
      isEmpty,
    );
  });
  test('Legacy per-dialog photo preview does not sign media', () async {
    photoRows = true;
    await Future.wait(
      List.generate(
        20,
        (i) =>
            ChatService.forTesting().fetchLatestWith('friend-$i', strict: true),
      ),
    );
    expect(
      requests.where((r) => r.url.path.endsWith('/chat_messages')).length,
      20,
    );
    expect(
      requests.where((r) => r.url.path.contains('/object/sign/')).length,
      0,
    );
  });
  testWidgets('Restored private photo automatically requests a usable URL', (
    t,
  ) async {
    final message = ChatMessage.fromRow({
      ...row('cached-photo', photo: true),
      'photo_url': 'https://audit.example.invalid/signed.jpg?token=old',
      'photo_reference': 'chat:$peer/audit.jpg',
    });
    final store = ChatLocalStore(me, peer);
    await store.saveMessages([message]);
    final restored = (await store.readMessages()).single;
    expect(restored.photoUrl, 'chat:$peer/audit.jpg');
    var retries = 0;
    await t.runAsync(() async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPhoto(
              source: restored.photoUrl!,
              onRetry: () async {
                retries++;
              },
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await t.pump();
    expect(
      requests.where((r) => r.url.path.contains('/object/sign/')),
      isNotEmpty,
    );
    expect(retries, 0);
    await t.pumpWidget(const SizedBox());
  });
}
