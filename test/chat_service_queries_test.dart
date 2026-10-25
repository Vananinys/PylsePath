import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/models/chat_message.dart';
import 'package:pulsepath/services/chat_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const me = '00000000-0000-4000-8000-000000000001';
  const friend = '00000000-0000-4000-8000-000000000002';
  const messageId = '00000000-0000-4000-8000-000000000003';
  final requests = <http.Request>[];
  final row = {
    'id': messageId,
    'sender_id': me,
    'receiver_id': friend,
    'body': 'Совпадение',
    'created_at': '2026-10-17T10:00:00Z',
    'reactions': <String, dynamic>{},
  };
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/token')) {
        final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
        String part(Object data) =>
            base64Url.encode(utf8.encode(jsonEncode(data))).replaceAll('=', '');
        return http.Response(
          jsonEncode({
            'access_token':
                '${part({'alg': 'HS256'})}.${part({'sub': me, 'exp': exp})}.signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'fake-refresh',
            'user': {
              'id': me,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'test@example.invalid',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-10-17T00:00:00Z',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      if (request.url.path.endsWith('/chat_messages')) {
        return http.Response(
          jsonEncode(request.method == 'POST' ? row : [row]),
          request.method == 'POST' ? 201 : 200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      return http.Response(
        '[]',
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    await Supabase.initialize(
      url: 'https://messenger-test.example.invalid',
      publishableKey: 'test-only',
      httpClient: client,
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'test@example.invalid',
      password: 'test-only',
    );
    requests.clear();
  });
  tearDownAll(() async {
    ChatService().resetSession();
    await Supabase.instance.dispose();
  });
  setUp(requests.clear);

  test('History pagination uses a stable timestamp and id cursor in both directions', () async {
    final cursor = ChatMessage(
      id: messageId,
      senderId: me,
      receiverId: friend,
      createdAt: DateTime.utc(2026, 10, 17, 11),
    );
    await ChatService().fetchConversation(friend, before: cursor, strict: true);
    final queries = requests
        .where((request) => request.url.path.endsWith('/chat_messages'))
        .toList();
    expect(queries.length, 2);
    for (final query in queries) {
      expect(query.url.queryParameters['or'], contains('id.lt.$messageId'));
      expect(
        query.url.queryParameters['order'],
        'created_at.desc.nullslast,id.desc.nullslast',
      );
      expect(query.url.queryParameters['limit'], '60');
    }
    expect(
      queries.map((query) => query.url.queryParameters['sender_id']).toSet(),
      {'eq.$me', 'eq.$friend'},
    );
  });

  test('Search treats percent and underscore as literal characters', () async {
    await ChatService().fetchConversation(
      friend,
      search: '50%_test',
      strict: true,
    );
    expect(requests.first.url.queryParameters['body'], r'ilike.%50\%\_test%');
  });

  test(
    'Retry finds the acknowledged message without a second insert',
    () async {
      final saved = await ChatService().sendMessage(
        friend,
        messageId: messageId,
        retry: true,
        text: 'Совпадение',
      );
      expect(saved?.id, messageId);
      expect(requests.any((request) => request.method == 'POST'), isFalse);
    },
  );
}
