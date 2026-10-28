// Compatibility of the local private-chat queue (a bare JSON array of rows).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/data/chat_local_store.dart';
import 'package:pulsepath/models/chat_message.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../deepseek_integrity/network_guard.dart';
import 'qa_support.dart';

const owner = 'owner-a';
const friend = 'friend-1';
const chatKey = 'chat_v1_${friend}_$owner';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(NetworkGuard.install);
  tearDownAll(NetworkGuard.restore);

  late QaPreferencesStore platform;
  late SharedPreferencesStorePlatform previousPlatform;

  setUp(() {
    previousPlatform = SharedPreferencesStorePlatform.instance;
    platform = QaPreferencesStore();
    SharedPreferencesStorePlatform.instance = platform;
    SharedPreferences.resetStatic();
  });

  tearDown(() {
    SharedPreferencesStorePlatform.instance = previousPlatform;
    SharedPreferences.resetStatic();
  });

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  Future<Object?> durable(String key) async =>
      (await platform.getAll())['flutter.$key'];

  Future<List<String>> damagedValues(String key) async {
    final all = await platform.getAll();
    return [
      for (final entry in all.entries)
        if (entry.key.startsWith('flutter.${key}_damaged_'))
          entry.value as String,
    ];
  }

  ChatMessage message(
    String id, {
    MessageDelivery delivery = MessageDelivery.sent,
  }) => ChatMessage(
    id: id,
    senderId: owner,
    receiverId: friend,
    body: 'Текст $id',
    createdAt: DateTime.utc(2026, 10, 28, 10),
    delivery: delivery,
  );

  test(
    'an unreadable pending queue is archived before a new save replaces it',
    () async {
      final store = await prefs();
      const original =
          '[{"id":"pending-qa-1","sender_id":"owner-a",'
          '"receiver_id":"friend-1","body":"не отправлено",'
          '"created_at":"2026-10-28T10:00:00.000Z","delivery_status":"sending"}'
          ',"truncated"';
      await store.setString(chatKey, original);

      final local = ChatLocalStore(owner, friend, currentOwner: () => owner);
      // Preserve unreadable primary bytes and start a separate writable archive.
      await local.readMessages();
      await local.saveMessages([message('server-1')]);

      expect(await damagedValues(chatKey), contains(original));
      final stored = (await durable(chatKey)) as String;
      final archived = (await damagedValues(chatKey))
          .any((value) => value.contains('pending-qa-1'));
      expect(
        stored.contains('pending-qa-1') || archived,
        isTrue,
        reason:
            'the only copy of an unsent message was overwritten after the '
            'queue failed to parse, without a backup or an error',
      );
    },
  );

  test('a legacy queue without delivery/status fields reopens and keeps pending text', () async {
    final store = await prefs();
    await store.setString(
      chatKey,
      jsonEncode([
        {
          'id': 'legacy-1',
          'sender_id': owner,
          'receiver_id': friend,
          'body': 'старое сообщение',
          'created_at': '2026-10-01T10:00:00.000Z',
        },
        {
          'id': 'legacy-2',
          'sender_id': friend,
          'receiver_id': owner,
          'body': 'ответ',
          'created_at': '2026-10-01T10:01:00.000Z',
        },
      ]),
    );

    final reopened = ChatLocalStore(owner, friend, currentOwner: () => owner);
    final rows = await reopened.readMessages();
    expect(rows.map((row) => row.id), ['legacy-1', 'legacy-2']);
    expect(rows.map((row) => row.body), ['старое сообщение', 'ответ']);
    expect(rows.map((row) => row.delivery), [
      MessageDelivery.sent,
      MessageDelivery.sent,
    ]);

    await reopened.saveMessages(rows);
    SharedPreferences.resetStatic();
    final afterRestart = await ChatLocalStore(
      owner,
      friend,
      currentOwner: () => owner,
    ).readMessages();
    expect(afterRestart.map((row) => row.id), ['legacy-1', 'legacy-2']);
    expect(afterRestart.map((row) => row.body), ['старое сообщение', 'ответ']);
  });
}
