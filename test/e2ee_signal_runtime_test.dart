import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

void main() {
  test('Signal native runtime can generate independent identities', () async {
    await LibSignal.init();
    final alice = IdentityKeyPair.generate();
    final bob = IdentityKeyPair.generate();
    expect(alice.publicKey, isNot(orderedEquals(bob.publicKey)));
    expect(alice.publicKey, isNotEmpty);
  });

  test(
    'native Signal exchanges messages and rejects tampering and replay',
    () async {
      await LibSignal.init();
      final alice = _Device('alice', 111);
      final bob = _Device('bob', 222);
      final pre = PrivateKey.generate();
      final signed = PrivateKey.generate();
      final signedSignature = bob.identity.sign(
        message: signed.getPublicKey().serialize().toList(),
      );
      final kyber = KyberKeyPair.generate();
      final kyberPublic = kyber.getPublicKey().serialize();
      final kyberSignature = bob.identity.sign(message: kyberPublic.toList());
      final now = BigInt.from(DateTime.now().millisecondsSinceEpoch);
      await bob.preKeys.storePreKey(
        1,
        PreKeyRecord(id: 1, publicKey: pre.getPublicKey(), privateKey: pre),
      );
      await bob.signedKeys.storeSignedPreKey(
        1,
        SignedPreKeyRecord(
          id: 1,
          publicKey: signed.getPublicKey(),
          privateKey: signed,
          signature: signedSignature.toList(),
          timestamp: now,
        ),
      );
      await bob.kyberKeys.storeKyberPreKey(
        1,
        KyberPreKeyRecord.create(
          id: 1,
          keyPair: kyber,
          signature: kyberSignature.toList(),
          timestamp: now,
        ),
      );
      await SessionBuilder(
        localAddress: alice.address,
        sessionStore: alice.sessions,
        identityKeyStore: alice.identities,
      ).processPreKeyBundle(
        bob.address,
        PreKeyBundle(
          registrationId: 222,
          deviceId: 1,
          preKeyId: 1,
          preKeyPublic: pre.getPublicKey().serialize(),
          signedPreKeyId: 1,
          signedPreKeyPublic: signed.getPublicKey().serialize().toList(),
          signedPreKeySignature: signedSignature.toList(),
          identityKey: bob.identity.publicKey.toList(),
          kyberPreKeyId: 1,
          kyberPreKeyPublic: kyberPublic.toList(),
          kyberPreKeySignature: kyberSignature.toList(),
        ),
      );
      final first = await alice.cipher.encrypt(
        bob.address,
        Uint8List.fromList(utf8.encode('Личное сообщение')),
      );
      expect(
        utf8.decode(await bob.cipher.decrypt(alice.address, first)),
        'Личное сообщение',
      );
      await expectLater(
        bob.cipher.decrypt(alice.address, first),
        throwsA(anything),
      );
      final reply = await bob.cipher.encrypt(
        alice.address,
        Uint8List.fromList(utf8.encode('Ответ')),
      );
      final damaged = Uint8List.fromList(reply.ciphertext);
      damaged[damaged.length - 1] ^= 1;
      await expectLater(
        alice.cipher.decrypt(
          bob.address,
          CiphertextMessage(type: reply.type, ciphertext: damaged),
        ),
        throwsA(anything),
      );
      // A rejected forged packet must not consume the genuine message's key.
      expect(
        utf8.decode(await alice.cipher.decrypt(bob.address, reply)),
        'Ответ',
      );
      final second = await alice.cipher.encrypt(
        bob.address,
        Uint8List.fromList(utf8.encode('Второе')),
      );
      final third = await alice.cipher.encrypt(
        bob.address,
        Uint8List.fromList(utf8.encode('Третье')),
      );
      expect(
        utf8.decode(await bob.cipher.decrypt(alice.address, third)),
        'Третье',
      );
      expect(
        utf8.decode(await bob.cipher.decrypt(alice.address, second)),
        'Второе',
      );
    },
  );
}

// Test-only stores: production must durably commit protocol state.
class _Device {
  _Device(String name, int registrationId)
    : address = ProtocolAddress(name: name, deviceId: 1) {
    identities = InMemoryIdentityKeyStore(identity, registrationId);
    cipher = SessionCipher(
      localAddress: address,
      sessionStore: sessions,
      identityKeyStore: identities,
      preKeyStore: preKeys,
      signedPreKeyStore: signedKeys,
      kyberPreKeyStore: kyberKeys,
    );
  }
  final ProtocolAddress address;
  final identity = IdentityKeyPair.generate();
  final sessions = InMemorySessionStore();
  final preKeys = InMemoryPreKeyStore();
  final signedKeys = InMemorySignedPreKeyStore();
  final kyberKeys = InMemoryKyberPreKeyStore();
  late final InMemoryIdentityKeyStore identities;
  late final SessionCipher cipher;
}
