import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:pulsepath/services/e2ee_box_codec.dart';

void main() {
  test(
    'recipients and sender read, outsider cannot; context is authenticated',
    () async {
      final sodium = await SodiumInit.init();
      final codec = E2eeBoxCodec(sodium);
      final alice = sodium.crypto.box.keyPair();
      final bob = sodium.crypto.box.keyPair();
      final eve = sodium.crypto.box.keyPair();
      try {
        final envelope = codec.encrypt(
          id: 'm1',
          sender: 'alice',
          conversation: 'dm:alice:bob',
          senderSecret: alice.secretKey,
          recipients: {'alice': alice.publicKey, 'bob': bob.publicKey},
          payload: {
            'body': 'секрет',
            'route': [
              [1, 2],
            ],
          },
        );
        expect(jsonEncode(envelope), isNot(contains('секрет')));
        Map<String, dynamic> open(
          String who,
          SecureKey secret, {
          String id = 'm1',
          String room = 'dm:alice:bob',
        }) => codec.decrypt(
          envelope: envelope,
          id: id,
          sender: 'alice',
          conversation: room,
          recipient: who,
          senderPublic: alice.publicKey,
          recipientSecret: secret,
        );
        expect(open('alice', alice.secretKey)['body'], 'секрет');
        expect(open('bob', bob.secretKey)['body'], 'секрет');
        expect(() => open('eve', eve.secretKey), throwsA(anything));
        expect(() => open('bob', eve.secretKey), throwsA(anything));
        expect(() => open('bob', bob.secretKey, id: 'm2'), throwsA(anything));
        expect(
          () => open('bob', bob.secretKey, room: 'other'),
          throwsA(anything),
        );
        final packet = (envelope['recipients'] as Map)['bob'] as Map;
        final Uint8List cipher = base64Url.decode(
          packet['ciphertext'] as String,
        );
        cipher[0] ^= 1;
        packet['ciphertext'] = base64UrlEncode(cipher);
        expect(() => open('bob', bob.secretKey), throwsA(anything));
      } finally {
        alice.secretKey.dispose();
        bob.secretKey.dispose();
        eve.secretKey.dispose();
      }
    },
  );
}
