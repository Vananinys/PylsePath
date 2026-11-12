import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:libsignal/libsignal.dart';

import '../data/signal_protocol_stores.dart';
import '../data/signal_state_database.dart';

/// Offline protocol engine. Transport must send only the returned packet after
/// run() commits. A retry reuses the persisted packet, never another ratchet step.
class SignalMessageEngine {
  SignalMessageEngine(this.database);
  final SignalStateDatabase database;
  static const format = 'pulsepath-signal-v2';
  dynamic _canonical(dynamic value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  Future<void> approveDevice(String user, int device, PublicKey key) =>
      database.run((stores, _) async {
        if (user.isEmpty ||
            user == database.owner ||
            device <= 0 ||
            device > 127) {
          throw ArgumentError('Invalid device');
        }
        await stores.saveIdentity(
          ProtocolAddress(name: user, deviceId: device),
          key,
        );
      });

  SessionCipher _cipher(SignalProtocolStores s, Map<String, dynamic> state) =>
      SessionCipher(
        localAddress: ProtocolAddress(
          name: database.owner,
          deviceId: state['device'] as int,
        ),
        sessionStore: s,
        identityKeyStore: s,
        preKeyStore: s,
        signedPreKeyStore: s,
        kyberPreKeyStore: s,
      );

  Future<Map<String, dynamic>> encrypt({
    required String id,
    required String conversation,
    required String recipient,
    required int recipientDevice,
    required Map<String, dynamic> payload,
    PreKeyBundle? bundle,
  }) => database.runRecords((stores, state, records) async {
    if (id.isEmpty ||
        conversation.isEmpty ||
        recipient.isEmpty ||
        recipientDevice <= 0 ||
        recipientDevice > 127 ||
        recipient == database.owner) {
      throw ArgumentError('Invalid Signal message context');
    }
    final context = <String, dynamic>{
      'v': format,
      'id': id,
      'conversation': conversation,
      'sender': database.owner,
      'senderDevice': state['device'],
      'recipient': recipient,
      'recipientDevice': recipientDevice,
      'payload': payload,
    };
    final encoded = jsonEncode(_canonical(context));
    if (utf8.encode(encoded).length > 32768) {
      throw ArgumentError('Signal message too large');
    }
    final previous = await records.read('outbox', id);
    final digest = sha256.convert(utf8.encode(encoded)).toString();
    if (previous != null) {
      if (previous['digest'] != digest) {
        throw StateError('Signal message ID reused with different content');
      }
      return Map<String, dynamic>.from(previous['packet'] as Map);
    }
    final address = ProtocolAddress(name: recipient, deviceId: recipientDevice);
    if (await stores.getIdentity(address) == null) {
      throw StateError('Signal device must be verified before migration');
    }
    if (!await stores.containsSession(address)) {
      if (bundle == null) {
        throw StateError('Verified device prekey bundle required');
      }
      await SessionBuilder(
        localAddress: ProtocolAddress(
          name: database.owner,
          deviceId: state['device'] as int,
        ),
        sessionStore: stores,
        identityKeyStore: stores,
      ).processPreKeyBundle(address, bundle);
    }
    final ciphertext = await _cipher(
      stores,
      state,
    ).encrypt(address, Uint8List.fromList(utf8.encode(encoded)));
    final packet = <String, dynamic>{...context}..remove('payload');
    packet['type'] = ciphertext.type.value;
    packet['ciphertext'] = base64Encode(ciphertext.ciphertext);
    await records.write('outbox', id, {'digest': digest, 'packet': packet});
    await records.write('archive', id, context);
    return packet;
  });

  Future<Map<String, dynamic>> decrypt({
    required String id,
    required String conversation,
    required String sender,
    required int senderDevice,
    required Map<String, dynamic> packet,
  }) => database.runRecords((stores, state, records) async {
    final expected = <String, dynamic>{
      'v': format,
      'id': id,
      'conversation': conversation,
      'sender': sender,
      'senderDevice': senderDevice,
      'recipient': database.owner,
      'recipientDevice': state['device'],
    };
    if (sender == database.owner ||
        senderDevice <= 0 ||
        senderDevice > 127 ||
        packet.length != 9 ||
        !const [2, 3].contains(packet['type']) ||
        expected.entries.any((e) => packet[e.key] != e.value)) {
      throw const FormatException('Signal packet context mismatch');
    }
    final digest = sha256
        .convert(utf8.encode(jsonEncode(_canonical(packet))))
        .toString();
    final previous = await records.read('inbox', id);
    if (previous != null) {
      if (previous['digest'] != digest) {
        throw const FormatException('Signal packet substitution');
      }
      return Map<String, dynamic>.from(previous['payload'] as Map);
    }
    final bytes = base64Decode(packet['ciphertext'] as String);
    if (bytes.isEmpty || bytes.length > 65536) {
      throw const FormatException('Invalid Signal packet size');
    }
    if (await stores.getIdentity(
          ProtocolAddress(name: sender, deviceId: senderDevice),
        ) ==
        null) {
      throw StateError('Unverified Signal device');
    }
    final plaintext = await _cipher(stores, state).decrypt(
      ProtocolAddress(name: sender, deviceId: senderDevice),
      CiphertextMessage.fromRaw(
        messageType: packet['type'] as int,
        ciphertext: Uint8List.fromList(bytes),
      ),
    );
    final context = jsonDecode(utf8.decode(plaintext)) as Map;
    if (context.length != 8 ||
        expected.entries.any((e) => context[e.key] != e.value) ||
        context['payload'] is! Map) {
      throw const FormatException('Signal authenticated context mismatch');
    }
    final payload = Map<String, dynamic>.from(context['payload'] as Map);
    await records.write('inbox', id, {'digest': digest, 'payload': payload});
    await records.write('archive', id, Map<String, dynamic>.from(context));
    return payload;
  });
}
