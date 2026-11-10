import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

/// Candidate codec using standard crypto_box independently for each recipient.
/// No shared group content key, no ratchet/forward secrecy. Not a deployed protocol.
/// Callers must pin keys and authorize current conversation membership.
class E2eeBoxCodec {
  E2eeBoxCodec(this.sodium);
  final Sodium sodium;
  static const version = 'pulsepath-box-v1';

  Map<String, dynamic> encrypt({
    required String id,
    required String sender,
    required String conversation,
    required SecureKey senderSecret,
    required Map<String, Uint8List> recipients,
    required Map<String, dynamic> payload,
  }) {
    if (id.isEmpty ||
        sender.isEmpty ||
        conversation.isEmpty ||
        !recipients.containsKey(sender) ||
        recipients.length > 200) {
      throw const FormatException('Invalid encrypted message context');
    }
    final body = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': version,
          'id': id,
          'sender': sender,
          'conversation': conversation,
          'payload': payload,
        }),
      ),
    );
    if (body.length > 2 * 1024 * 1024) {
      throw const FormatException('Encrypted message too large');
    }
    final packets = <String, dynamic>{};
    for (final recipient in recipients.entries) {
      final nonce = sodium.randombytes.buf(sodium.crypto.box.nonceBytes);
      packets[recipient.key] = {
        'nonce': base64UrlEncode(nonce),
        'ciphertext': base64UrlEncode(
          sodium.crypto.box.easy(
            message: body,
            nonce: nonce,
            publicKey: recipient.value,
            secretKey: senderSecret,
          ),
        ),
      };
    }
    final result = <String, dynamic>{'v': version, 'recipients': packets};
    if (jsonEncode(result).length > 8 * 1024 * 1024) {
      throw const FormatException('Encrypted envelope too large');
    }
    return result;
  }

  Map<String, dynamic> decrypt({
    required Map<String, dynamic> envelope,
    required String id,
    required String sender,
    required String conversation,
    required String recipient,
    required Uint8List senderPublic,
    required SecureKey recipientSecret,
  }) {
    if (envelope['v'] != version ||
        jsonEncode(envelope).length > 8 * 1024 * 1024) {
      throw const FormatException('Invalid encrypted message version/size');
    }
    final packet = (envelope['recipients'] as Map)[recipient] as Map?;
    if (packet == null) {
      throw const FormatException('Not an encrypted recipient');
    }
    final raw = sodium.crypto.box.openEasy(
      cipherText: base64Url.decode(packet['ciphertext'] as String),
      nonce: base64Url.decode(packet['nonce'] as String),
      publicKey: senderPublic,
      secretKey: recipientSecret,
    );
    try {
      final body = jsonDecode(utf8.decode(raw)) as Map;
      if (body['v'] != version ||
          body['id'] != id ||
          body['sender'] != sender ||
          body['conversation'] != conversation) {
        throw const FormatException('Encrypted message context mismatch');
      }
      return Map<String, dynamic>.from(body['payload'] as Map);
    } finally {
      raw.fillRange(0, raw.length, 0);
    }
  }
}
