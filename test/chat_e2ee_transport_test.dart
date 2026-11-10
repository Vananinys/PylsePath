import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/config/app_variant.dart';
import 'package:pulsepath/data/chat_local_store.dart';
import 'package:pulsepath/services/chat_service.dart';

const aliceId = '00000000-0000-4000-8000-000000000001';
const bobId = '00000000-0000-4000-8000-000000000002';
const messageId = '00000000-0000-4000-8000-000000000003';

class Fixture {
  final identities = <String, String>{};
  final backups = <String, String>{};
  final messages = <String, Map<String, dynamic>>{};
  final wire = <Map<String, dynamic>>[];
  final clients = <SupabaseClient>[];
  int uploads = 0;
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
        if (path.contains('/storage/')) {
          uploads++;
          return json({});
        }
        if (path.endsWith('/rpc/e2ee_register_identity')) {
          final data = jsonDecode(r.body) as Map;
          identities[id] = data['p_public_key'] as String;
          backups[id] = data['p_backup'] as String;
          return json(null);
        }
        if (path.endsWith('/e2ee_identities')) {
          final who = (r.url.queryParameters['user_id'] ?? 'eq.').substring(3);
          return json(
            identities.containsKey(who)
                ? [
                    {'public_key': identities[who]},
                  ]
                : [],
          );
        }
        if (path.endsWith('/e2ee_recovery_backups')) {
          return json({'envelope': backups[id]});
        }
        if (path.endsWith('/chat_messages')) {
          if (r.method == 'POST') {
            final data = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
            wire.add(data);
            final row = {
              ...data,
              'created_at': '2026-11-10T00:00:00Z',
              'reactions': <String, dynamic>{},
            };
            messages[data['id'] as String] = row;
            return json(row, 201);
          }
          final key = (r.url.queryParameters['id'] ?? 'eq.').substring(3);
          return json(messages.containsKey(key) ? [messages[key]] : []);
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
  late Fixture fixture;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    fixture = Fixture();
  });
  tearDown(() async => fixture.close());
  test('real chat service sends no open text or sticker and hydrates the peer copy', () async {
    final a = ChatService.forTesting(client: await fixture.client(aliceId));
    final b = ChatService.forTesting(client: await fixture.client(bobId));
    await b.encryption.ensure();
    final sent = await a.sendMessage(
      bobId,
      text: 'private fixture',
      sticker: '🚴',
      messageId: messageId,
    );
    expect(sent?.isEncrypted, isTrue);
    expect(sent?.body, 'private fixture');
    final encoded = jsonEncode(fixture.wire.single);
    expect(encoded, isNot(contains('private fixture')));
    expect(encoded, isNot(contains('🚴')));
    expect(fixture.wire.single.containsKey('sticker'), isFalse);
    final received = await b.fetchMessage(messageId);
    expect(received?.body, 'private fixture');
    expect(received?.sticker, '🚴');
    expect(received?.decryptionFailed, isFalse);
    expect(received?.withDelivery(received.delivery).isEncrypted, isTrue);
    final envelope = fixture.messages[messageId]!['encrypted_payload'] as Map;
    final packet = (envelope['recipients'] as Map)[bobId] as Map;
    final cipher = base64Url.decode(packet['ciphertext'] as String);
    cipher[0] ^= 1;
    packet['ciphertext'] = base64UrlEncode(cipher);
    final damaged = await b.fetchMessage(messageId);
    expect(damaged?.decryptionFailed, isTrue);
    expect(damaged?.body, isNot('private fixture'));
  }, skip: !AppVariant.e2eeMessaging);
  test(
    'missing peer key and attachments never fall back to open writes',
    () async {
      final a = ChatService.forTesting(client: await fixture.client(aliceId));
      await expectLater(
        a.sendMessage(bobId, text: 'must not leak', messageId: messageId),
        throwsA(isA<ChatServiceException>()),
      );
      expect(fixture.wire, isEmpty);
      await expectLater(
        a.sendMessage(
          bobId,
          text: 'caption',
          photoPath: 'fixture.jpg',
          messageId: messageId,
        ),
        throwsA(isA<ChatServiceException>()),
      );
      expect(fixture.uploads, 0);
      expect(fixture.wire, isEmpty);
    },
    skip: !AppVariant.e2eeMessaging,
  );
  test(
    'beta queue and drafts use protected storage and preserve legacy data',
    () async {
      final prefs = await SharedPreferences.getInstance();
      const legacy = 'old local draft';
      await prefs.setString('chat_v1_${bobId}_${aliceId}_draft', legacy);
      final store = ChatLocalStore(aliceId, bobId, currentOwner: () => aliceId);
      expect(await store.readDraft(), legacy);
      await store.saveDraft('new protected draft');
      expect(await store.readDraft(), 'new protected draft');
      expect(prefs.getString('chat_v1_${bobId}_${aliceId}_draft'), legacy);
      expect(
        prefs.getKeys().map((k) => prefs.get(k)).join(),
        isNot(contains('new protected draft')),
      );
      final other = ChatLocalStore(aliceId, bobId, currentOwner: () => bobId);
      await expectLater(other.readDraft(), throwsStateError);
    },
    skip: !AppVariant.e2eeMessaging,
  );
}
