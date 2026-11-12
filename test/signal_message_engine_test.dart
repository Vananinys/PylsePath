import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal/libsignal.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pulsepath/data/signal_state_database.dart';
import 'package:pulsepath/services/signal_message_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  test(
    'durable Signal exchange, reopen, retries, context and cached history',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp(
        'pulsepath-signal-engine-',
      );
      Future<SignalStateDatabase> open(String owner) =>
          SignalStateDatabase.open(
            path: '${dir.path}/$owner.db',
            owner: owner,
            currentOwner: () => owner,
          );
      var ad = await open('alice'), bd = await open('bob');
      await ad.enrollNewDevice();
      await bd.enrollNewDevice();
      var alice = SignalMessageEngine(ad), bob = SignalMessageEngine(bd);
      final ai = await ad.run(
        (s, state) async =>
            (id: state['device'] as int, key: await s.getIdentityKeyPair()),
      );
      final bi = await bd.run(
        (s, state) async =>
            (id: state['device'] as int, key: await s.getIdentityKeyPair()),
      );
      await alice.approveDevice(
        'bob',
        bi.id,
        PublicKey.deserialize(bytes: bi.key.publicKey.toList()),
      );
      await bob.approveDevice(
        'alice',
        ai.id,
        PublicKey.deserialize(bytes: ai.key.publicKey.toList()),
      );
      final bundle = await bd.run((s, state) async {
        final pre = PrivateKey.generate(), signed = PrivateKey.generate();
        final kyber = KyberKeyPair.generate();
        final signature = bi.key.sign(
          message: signed.getPublicKey().serialize().toList(),
        );
        final kp = kyber.getPublicKey().serialize();
        final ks = bi.key.sign(message: kp.toList());
        final now = BigInt.from(DateTime.now().millisecondsSinceEpoch);
        await s.storePreKey(
          1,
          PreKeyRecord(id: 1, publicKey: pre.getPublicKey(), privateKey: pre),
        );
        await s.storeSignedPreKey(
          1,
          SignedPreKeyRecord(
            id: 1,
            publicKey: signed.getPublicKey(),
            privateKey: signed,
            signature: signature.toList(),
            timestamp: now,
          ),
        );
        await s.storeKyberPreKey(
          1,
          KyberPreKeyRecord.create(
            id: 1,
            keyPair: kyber,
            signature: ks.toList(),
            timestamp: now,
          ),
        );
        return PreKeyBundle(
          registrationId: await s.getLocalRegistrationId(),
          deviceId: bi.id,
          preKeyId: 1,
          preKeyPublic: pre.getPublicKey().serialize(),
          signedPreKeyId: 1,
          signedPreKeyPublic: signed.getPublicKey().serialize().toList(),
          signedPreKeySignature: signature.toList(),
          identityKey: bi.key.publicKey.toList(),
          kyberPreKeyId: 1,
          kyberPreKeyPublic: kp.toList(),
          kyberPreKeySignature: ks.toList(),
        );
      });
      final packet = await alice.encrypt(
        id: 'one',
        conversation: 'room',
        recipient: 'bob',
        recipientDevice: bi.id,
        payload: {'body': 'private', 'sticker': null},
        bundle: bundle,
      );
      expect(jsonEncode(packet), isNot(contains('private')));
      await ad.close();
      ad = await open('alice');
      alice = SignalMessageEngine(ad);
      final retry = await alice.encrypt(
        id: 'one',
        conversation: 'room',
        recipient: 'bob',
        recipientDevice: bi.id,
        payload: {'sticker': null, 'body': 'private'},
      );
      expect(retry, packet);
      await expectLater(
        alice.encrypt(
          id: 'one',
          conversation: 'room',
          recipient: 'bob',
          recipientDevice: bi.id,
          payload: {'body': 'different'},
        ),
        throwsStateError,
      );
      expect(
        (await bob.decrypt(
          id: 'one',
          conversation: 'room',
          sender: 'alice',
          senderDevice: ai.id,
          packet: packet,
        ))['body'],
        'private',
      );
      await bd.close();
      bd = await open('bob');
      bob = SignalMessageEngine(bd);
      final reordered = Map<String, dynamic>.fromEntries(
        packet.entries.toList().reversed,
      );
      expect(
        (await bob.decrypt(
          id: 'one',
          conversation: 'room',
          sender: 'alice',
          senderDevice: ai.id,
          packet: reordered,
        ))['body'],
        'private',
      );
      await expectLater(
        bob.decrypt(
          id: 'one',
          conversation: 'room',
          sender: 'alice',
          senderDevice: ai.id,
          packet: {...packet, 'ciphertext': 'bad'},
        ),
        throwsFormatException,
      );
      await expectLater(
        bob.decrypt(
          id: 'one',
          conversation: 'other',
          sender: 'alice',
          senderDevice: ai.id,
          packet: packet,
        ),
        throwsFormatException,
      );
      final reply = await bob.encrypt(
        id: 'two',
        conversation: 'room',
        recipient: 'alice',
        recipientDevice: ai.id,
        payload: {'body': 'reply'},
      );
      await expectLater(
        alice.decrypt(
          id: 'two',
          conversation: 'room',
          sender: 'bob',
          senderDevice: bi.id,
          packet: {
            ...reply,
            'ciphertext': base64Encode(List<int>.filled(100, 0)),
          },
        ),
        throwsA(anything),
      );
      expect(
        (await alice.decrypt(
          id: 'two',
          conversation: 'room',
          sender: 'bob',
          senderDevice: bi.id,
          packet: reply,
        ))['body'],
        'reply',
      );
      await ad.close();
      await bd.close();
    },
  );
}
