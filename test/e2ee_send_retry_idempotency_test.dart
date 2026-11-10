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
const messageId = '00000000-0000-4000-8000-000000000003';

/// Send idempotency: after a timeout the server may already have persisted
/// the row; a retry with the same client-side messageId must never create a
/// second row and must return the stored message (chat_service.dart
/// sendMessage retry fetch :254-261, 23505 fallback :373-380 — shared by the
/// E2EE and legacy paths).
class RetryFixture {
  final clients = <SupabaseClient>[];
  final rows = <String, Map<String, dynamic>>{};
  final wire = <Map<String, dynamic>>[];
  int duplicateConflict = 0;
  http.Request? _request;

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
        if (path.endsWith('/chat_messages')) {
          if (r.method == 'POST') {
            if (duplicateConflict > 0) {
              // The row exists server-side; the response was lost and the
              // next attempt hits the primary key conflict.
              duplicateConflict--;
              return json({
                'message': 'duplicate key value violates unique constraint "chat_messages_pkey"',
                'code': '23505',
              }, 409);
            }
            final data = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
            wire.add(data);
            final row = {
              ...data,
              'created_at': '2026-11-10T00:00:00Z',
              'reactions': <String, dynamic>{},
            };
            rows[data['id'] as String] = row;
            return json(row, 201);
          }
          final key = (r.url.queryParameters['id'] ?? 'eq.').substring(3);
          return json(rows.containsKey(key) ? [rows[key]] : []);
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

  test('retry with the same messageId after acceptance returns the stored row, no second insert', () async {
    final fixture = RetryFixture();
    final chat = ChatService.forTesting(client: await fixture.client(aliceId));
    final first = await chat.sendMessage(
      bobId,
      text: 'once',
      messageId: messageId,
    );
    expect(first?.id, messageId);
    expect(fixture.wire.length, 1);

    // Timeout scenario: the server holds the row, the client saw only a
    // failure. A manual retry must dedupe by messageId.
    final retry = await chat.sendMessage(
      bobId,
      text: 'once',
      messageId: messageId,
      retry: true,
    );
    expect(retry?.id, messageId);
    expect(retry?.body, 'once');
    expect(fixture.wire.length, 1, reason: 'no second insert on the wire');
    await fixture.close();
  });

  test('duplicate-key conflict falls back to fetching the stored row', () async {
    final fixture = RetryFixture();
    final chat = ChatService.forTesting(client: await fixture.client(aliceId));
    // The row exists server-side (accepted before the connection dropped);
    // the insert attempt hits 23505.
    fixture.rows[messageId] = {
      'id': messageId,
      'sender_id': aliceId,
      'receiver_id': bobId,
      'body': 'accepted earlier',
      'created_at': '2026-11-10T00:00:00Z',
      'reactions': <String, dynamic>{},
    };
    fixture.duplicateConflict = 1;
    // The E2EE path always supplies a client-generated messageId
    // (chat_service.dart:253); pass one to hit the same 23505 fallback.
    final saved = await chat.sendMessage(
      bobId,
      text: 'accepted earlier',
      messageId: messageId,
    );
    expect(saved?.id, messageId);
    expect(saved?.body, 'accepted earlier');
    expect(
      fixture.wire,
      isEmpty,
      reason: 'the conflicting insert persisted nothing; the stored row was '
          'returned instead of creating a duplicate',
    );
    await fixture.close();
  });
}
