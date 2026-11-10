import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/services/chat_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const aliceId = '00000000-0000-4000-8000-000000000001';
const bobId = '00000000-0000-4000-8000-000000000002';

/// Server-side e2ee_guard_chat rejects plaintext writes into a conversation
/// locked by the first encrypted message with 42501/E2EE_UPGRADE_REQUIRED
/// (docs/e2ee_chat_schema.sql:44-45).
class LockedFixture {
  final clients = <SupabaseClient>[];
  http.Request? _request;
  // postgrest_builder.dart reads response.request!, so the mock must attach it.
  http.Response json(Object? value, [int status = 200]) => http.Response(
    jsonEncode(value),
    status,
    request: _request,
    headers: {'content-type': 'application/json'},
  );

  Future<SupabaseClient> client(String id) async {
    String jwt() {
      String encode(Object v) =>
          base64UrlEncode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
      return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': id, 'role': 'authenticated', 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.fixture';
    }

    final c = SupabaseClient(
      'https://qa.example.invalid',
      'fixture-publishable-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        _request = r;
        final path = r.url.path;
        if (path.endsWith('/token')) {
          return json({
            'access_token': jwt(),
            'refresh_token': 'fixture-refresh',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': id,
              'email': 'fixture@example.invalid',
              'aud': 'authenticated',
              'created_at': '2026-11-10T00:00:00Z',
            },
          });
        }
        if (path.endsWith('/chat_messages') && r.method == 'POST') {
          return json({
            'message': 'E2EE_UPGRADE_REQUIRED',
            'code': '42501',
          }, 403);
        }
        return json({'message': 'unexpected test endpoint'}, 500);
      }),
    );
    clients.add(c);
    await c.auth.signInWithPassword(
      email: 'fixture@example.invalid',
      password: 'fixture-only',
    );
    return c;
  }

  Future<void> close() async {
    for (final c in clients) {
      await c.dispose();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'stable client in a locked conversation gets an upgrade hint, not a network error',
    () async {
      final fixture = LockedFixture();
      final chat = ChatService.forTesting(client: await fixture.client(aliceId));
      await expectLater(
        chat.sendMessage(bobId, text: 'plain before lock'),
        throwsA(
          isA<ChatServiceException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('защищённый режим'),
              contains('UI Beta'),
              isNot(contains('Проверьте интернет')),
            ),
          ),
        ),
      );
      await fixture.close();
    },
  );
}
