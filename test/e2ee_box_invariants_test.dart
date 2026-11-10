import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:pulsepath/services/e2ee_box_codec.dart';

/// Cryptographic invariants of the deployed crypto_box envelope, proven by
/// local execution (no network, no real keys). Existing e2ee_box_codec_test
/// covers tamper/id/conversation mismatch and outsider access; this file pins
/// the remaining invariants: nonce uniqueness, recipient packet swap,
/// nonce tamper, malformed packet formats and version downgrade refusal.
void main() {
  test('nonce uniqueness across repeated envelopes for the same pair', () async {
    final sodium = await SodiumInit.init();
    final codec = E2eeBoxCodec(sodium);
    final alice = sodium.crypto.box.keyPair();
    final bob = sodium.crypto.box.keyPair();
    try {
      final nonces = <String>{};
      for (var i = 0; i < 500; i++) {
        final envelope = codec.encrypt(
          id: 'm$i',
          sender: 'alice',
          conversation: 'dm:alice:bob',
          senderSecret: alice.secretKey,
          recipients: {'alice': alice.publicKey, 'bob': bob.publicKey},
          payload: {'body': 'секрет'},
        );
        final packets = envelope['recipients'] as Map;
        nonces.add((packets['alice'] as Map)['nonce'] as String);
        nonces.add((packets['bob'] as Map)['nonce'] as String);
      }
      // 1000 packets, each nonce must be fresh (crypto_box reuse catastrophe).
      expect(nonces.length, 1000);
    } finally {
      alice.secretKey.dispose();
      bob.secretKey.dispose();
    }
  });

  test('recipient packet swap inside an envelope is rejected', () async {
    final sodium = await SodiumInit.init();
    final codec = E2eeBoxCodec(sodium);
    final alice = sodium.crypto.box.keyPair();
    final bob = sodium.crypto.box.keyPair();
    try {
      final envelope = codec.encrypt(
        id: 'm1',
        sender: 'alice',
        conversation: 'dm:alice:bob',
        senderSecret: alice.secretKey,
        recipients: {'alice': alice.publicKey, 'bob': bob.publicKey},
        payload: {'body': 'секрет'},
      );
      final packets = envelope['recipients'] as Map<String, dynamic>;
      final ownPacket = packets['alice'];
      final peerPacket = packets['bob'];
      packets['alice'] = peerPacket;
      packets['bob'] = ownPacket;
      for (final who in ['alice', 'bob']) {
        expect(
          () => codec.decrypt(
            envelope: envelope,
            id: 'm1',
            sender: 'alice',
            conversation: 'dm:alice:bob',
            recipient: who,
            senderPublic: alice.publicKey,
            recipientSecret: who == 'alice'
                ? alice.secretKey
                : bob.secretKey,
          ),
          throwsA(anything),
          reason: 'Packet sealed for the other public key must fail MAC',
        );
      }
    } finally {
      alice.secretKey.dispose();
      bob.secretKey.dispose();
    }
  });

  test('nonce tamper and malformed packets fail closed', () async {
    final sodium = await SodiumInit.init();
    final codec = E2eeBoxCodec(sodium);
    final alice = sodium.crypto.box.keyPair();
    final bob = sodium.crypto.box.keyPair();
    try {
      Map<String, dynamic> build() => codec.encrypt(
        id: 'm1',
        sender: 'alice',
        conversation: 'dm:alice:bob',
        senderSecret: alice.secretKey,
        recipients: {'alice': alice.publicKey, 'bob': bob.publicKey},
        payload: {'body': 'секрет'},
      );
      Map<String, dynamic> open(
        Map<String, dynamic> envelope, {
        String who = 'bob',
      }) => codec.decrypt(
        envelope: envelope,
        id: 'm1',
        sender: 'alice',
        conversation: 'dm:alice:bob',
        recipient: who,
        senderPublic: alice.publicKey,
        recipientSecret: who == 'alice' ? alice.secretKey : bob.secretKey,
      );

      final envelope = build();
      final packets = envelope['recipients'] as Map<String, dynamic>;
      final peer = Map<String, dynamic>.from(packets['bob'] as Map);
      final nonce = base64Url.decode(peer['nonce'] as String);
      final Uint8List tampered = Uint8List.fromList(nonce);
      tampered[0] ^= 1;
      peer['nonce'] = base64UrlEncode(tampered);
      packets['bob'] = peer;
      expect(() => open(envelope), throwsA(anything));
      packets['bob'] = build()['recipients']['bob'];

      // Wrong key sizes and malformed base64 must throw, never crash.
      final short = Map<String, dynamic>.from(
        build()['recipients']['bob'] as Map,
      );
      short['ciphertext'] = 'AAAA';
      packets['bob'] = short;
      expect(() => open(envelope), throwsA(anything));

      final junk = Map<String, dynamic>.from(short);
      junk['ciphertext'] = '!!!not-base64!!!';
      packets['bob'] = junk;
      expect(() => open(envelope), throwsA(anything));

      // Missing recipient packet is rejected explicitly.
      packets.remove('bob');
      expect(() => open(envelope), throwsA(anything));
    } finally {
      alice.secretKey.dispose();
      bob.secretKey.dispose();
    }
  });

  test('future envelope version is refused (no silent downgrade)', () async {
    final sodium = await SodiumInit.init();
    final codec = E2eeBoxCodec(sodium);
    final alice = sodium.crypto.box.keyPair();
    final bob = sodium.crypto.box.keyPair();
    try {
      final envelope = codec.encrypt(
        id: 'm1',
        sender: 'alice',
        conversation: 'dm:alice:bob',
        senderSecret: alice.secretKey,
        recipients: {'alice': alice.publicKey, 'bob': bob.publicKey},
        payload: {'body': 'секрет'},
      );
      envelope['v'] = 'pulsepath-box-v2';
      expect(
        () => codec.decrypt(
          envelope: envelope,
          id: 'm1',
          sender: 'alice',
          conversation: 'dm:alice:bob',
          recipient: 'bob',
          senderPublic: alice.publicKey,
          recipientSecret: bob.secretKey,
        ),
        throwsA(anything),
      );
    } finally {
      alice.secretKey.dispose();
      bob.secretKey.dispose();
    }
  });
}
