import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/config.dart';
import 'package:pulsepath/config/app_variant.dart';
import 'package:pulsepath/data/chat_local_store.dart';
import 'package:pulsepath/services/chat_service.dart';
import 'package:pulsepath/utils/ride_id.dart';
import 'package:pulsepath/models/chat_message.dart';

class _LiveNetwork extends HttpOverrides {}

/// Explicitly opted-in live QA. Credentials are generated test accounts in a
/// local file outside the repository; neither credentials nor private keys log.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('LIVE_E2EE_QA');
  const path = String.fromEnvironment('E2EE_QA_CREDENTIALS');
  test(
    'real authenticated E2EE conversation, RLS, editing and recovery',
    () async {
      expect(AppVariant.e2eeMessaging, isTrue);
      final previousNetwork = HttpOverrides.current;
      HttpOverrides.global =
          _LiveNetwork(); // Explicit live QA, not Flutter's HTTP-400 stub.
      final users = (jsonDecode(await File(path).readAsString()) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final storeFile = File('$path.keystore');
      final initial = await storeFile.exists()
          ? Map<String, String>.from(
              jsonDecode(await storeFile.readAsString()) as Map,
            )
          : <String, String>{};
      FlutterSecureStorage.setMockInitialValues(initial);
      SharedPreferences.setMockInitialValues({});
      Future<void> persist() async => storeFile.writeAsString(
        jsonEncode(await const FlutterSecureStorage().readAll()),
        flush: true,
      );
      final clients = <SupabaseClient>[];
      final chats = <ChatService>[];
      Future<SupabaseClient> login(int index) async {
        final c = SupabaseClient(
          AppConfig.supabaseUrl,
          AppConfig.supabasePublishableKey,
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        await c.auth.signInWithPassword(
          email: users[index]['email'] as String,
          password: users[index]['password'] as String,
        );
        clients.add(c);
        return c;
      }

      try {
        final alice = await login(0),
            bob = await login(1),
            eve = await login(2);
        final a = ChatService.forTesting(client: alice),
            b = ChatService.forTesting(client: bob);
        chats.addAll([a, b]);
        await a.encryption.ensure();
        await persist();
        await b.encryption.ensure();
        await persist();
        final recovery = await b.encryption.exportRecoveryKey();
        final id = newRideId();
        final delivered = Completer<ChatMessage>();
        await b.subscribe((message) {
          if (message.id == id && !delivered.isCompleted) {
            delivered.complete(message);
          }
        });
        for (var i = 0; i < 150 && !b.connected.value; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          b.connected.value,
          isTrue,
          reason: 'Authenticated Realtime subscription must connect',
        );
        final phrase =
            'Live encrypted QA ${DateTime.now().microsecondsSinceEpoch}';
        final sent = await a.sendMessage(
          users[1]['id'] as String,
          text: phrase,
          messageId: id,
        );
        expect(sent?.body, phrase);
        expect(sent?.isEncrypted, isTrue);
        expect(
          (await delivered.future.timeout(const Duration(seconds: 30))).body,
          phrase,
        );
        final received = await b.fetchMessage(id);
        expect(received?.body, phrase);
        expect(received?.decryptionFailed, isFalse);
        final raw = await bob
            .from('chat_messages')
            .select()
            .eq('id', id)
            .single();
        expect(jsonEncode(raw), isNot(contains(phrase)));
        expect(raw['encrypted_payload'], isA<Map>());
        expect(raw['sticker'], isNull);
        expect(
          await eve.from('chat_messages').select('id').eq('id', id),
          isEmpty,
        );
        expect(
          await eve
              .from('e2ee_recovery_backups')
              .select('user_id')
              .eq('user_id', users[1]['id']),
          isEmpty,
        );
        expect(
          await alice
              .from('e2ee_recovery_backups')
              .select('user_id')
              .eq('user_id', users[1]['id']),
          isEmpty,
        );
        await expectLater(
          alice.from('chat_messages').insert({
            'id': newRideId(),
            'sender_id': users[0]['id'],
            'receiver_id': users[1]['id'],
            'body': 'plaintext bypass',
          }),
          throwsA(isA<PostgrestException>()),
        );
        await expectLater(
          bob
              .from('chat_messages')
              .update({
                'encrypted_payload': raw['encrypted_payload'],
                'body': 'tamper',
              })
              .eq('id', id),
          throwsA(isA<PostgrestException>()),
        );
        final changedPayload =
            jsonDecode(jsonEncode(raw['encrypted_payload'])) as Map;
        final packet =
            (changedPayload['recipients'] as Map)[users[0]['id']] as Map;
        final oldCipher = packet['ciphertext'] as String;
        packet['ciphertext'] =
            (oldCipher[0] == 'A' ? 'B' : 'A') + oldCipher.substring(1);
        await expectLater(
          bob
              .from('chat_messages')
              .update({'encrypted_payload': changedPayload})
              .eq('id', id),
          throwsA(isA<PostgrestException>()),
        );
        await expectLater(
          alice
              .from('chat_messages')
              .update({'encrypted_payload': null})
              .eq('id', id),
          throwsA(isA<PostgrestException>()),
        );
        await expectLater(
          alice
              .from('e2ee_identities')
              .update({'public_key': 'tamper'})
              .eq('user_id', users[0]['id']),
          throwsA(isA<PostgrestException>()),
        );
        final edited = await a.editMessage(id, '$phrase edited');
        expect(edited.body, '$phrase edited');
        expect(edited.editedAt, isNotNull);
        expect((await b.fetchMessage(id))?.body, '$phrase edited');
        expect(await b.markMessageRead((await b.fetchMessage(id))!), isTrue);
        final reply = await b.sendMessage(
          users[0]['id'] as String,
          text: 'Encrypted reply',
          sticker: '🚴',
          replyToId: id,
          messageId: newRideId(),
        );
        expect((await a.fetchMessage(reply!.id))?.sticker, '🚴');
        expect(
          (await a.fetchReplyTargets([reply]))[id]?.body,
          '$phrase edited',
        );
        await persist();
        final keptKeys = await const FlutterSecureStorage().readAll();
        FlutterSecureStorage.setMockInitialValues({});
        final bobNew = ChatService.forTesting(client: await login(1));
        await expectLater(bobNew.encryption.ensure(), throwsA(anything));
        await expectLater(
          bobNew.encryption.restore('wrong recovery key'),
          throwsA(anything),
        );
        await bobNew.encryption.restore(recovery);
        expect((await bobNew.fetchMessage(id))?.body, '$phrase edited');
        FlutterSecureStorage.setMockInitialValues({
          ...keptKeys,
          ...await const FlutterSecureStorage().readAll(),
        });
        await persist();
        final owner = users[0]['id'] as String,
            friend = users[1]['id'] as String;
        final cache = ChatLocalStore(owner, friend, currentOwner: () => owner);
        await cache.saveMessages([edited]);
        await cache.saveDraft('protected draft fixture');
        expect(
          (await ChatLocalStore(
            owner,
            friend,
            currentOwner: () => owner,
          ).readMessages()).single.body,
          '$phrase edited',
        );
        expect(await cache.readDraft(), 'protected draft fixture');
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getKeys().map((k) => prefs.get(k).toString()).join(),
          isNot(contains(phrase)),
        );
        expect(
          prefs.getKeys().map((k) => prefs.get(k).toString()).join(),
          isNot(contains('protected draft fixture')),
        );
        debugPrint(
          'Live QA passed: authenticated Realtime delivery, ciphertext-only rows, outsider denied, no plaintext downgrade, sender-only edit, reply/read, recovery and protected cache.',
        );
      } finally {
        await persist();
        for (final chat in chats) {
          chat.resetSession();
        }
        for (final c in clients) {
          await c.dispose();
        }
        HttpOverrides.global = previousNetwork;
      }
    },
    skip: !enabled || path.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
