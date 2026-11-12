import 'dart:convert';

import 'package:libsignal/libsignal.dart';
import 'package:sqflite/sqflite.dart';

import '../data/signal_state_database.dart';
import 'signal_message_engine.dart';

/// Local synthetic identities only. Never uses Supabase, auth or real chats.
Future<List<String>> runSignalDiagnostic() async {
  final checks = <String>[];
  void check(bool value, String label) {
    if (!value) throw StateError(label);
    checks.add(label);
  }

  final path = await getDatabasesPath();
  const aliceOwner = '__signal_lab_alice', bobOwner = '__signal_lab_bob';
  Future<SignalStateDatabase> open(String owner) => SignalStateDatabase.open(
    path: '$path/$owner.db',
    owner: owner,
    currentOwner: () => owner,
  );
  var ad = await open(aliceOwner), bd = await open(bobOwner);
  try {
    for (final db in [ad, bd]) {
      if (!await db.isEnrolled()) await db.enrollNewDevice();
    }
    final round = await ad.run((_, s) async {
      final n = (s['round'] as int? ?? 0) + 1;
      s['round'] = n;
      return n;
    });
    var alice = SignalMessageEngine(ad), bob = SignalMessageEngine(bd);
    final aliceIdentity = await ad.run(
      (s, state) async =>
          (id: state['device'] as int, key: await s.getIdentityKeyPair()),
    );
    final bobIdentity = await bd.run(
      (s, state) async =>
          (id: state['device'] as int, key: await s.getIdentityKeyPair()),
    );
    await alice.approveDevice(
      bobOwner,
      bobIdentity.id,
      PublicKey.deserialize(bytes: bobIdentity.key.publicKey.toList()),
    );
    await bob.approveDevice(
      aliceOwner,
      aliceIdentity.id,
      PublicKey.deserialize(bytes: aliceIdentity.key.publicKey.toList()),
    );
    final hasSession = await ad.run(
      (s, _) => s.containsSession(
        ProtocolAddress(name: bobOwner, deviceId: bobIdentity.id),
      ),
    );
    final bundle = hasSession
        ? null
        : await bd.run((s, state) async {
            final pre = PrivateKey.generate(), signed = PrivateKey.generate();
            final kyber = KyberKeyPair.generate();
            final signature = bobIdentity.key.sign(
              message: signed.getPublicKey().serialize().toList(),
            );
            final kp = kyber.getPublicKey().serialize();
            final ks = bobIdentity.key.sign(message: kp.toList());
            final now = BigInt.from(DateTime.now().millisecondsSinceEpoch);
            await s.storePreKey(
              1,
              PreKeyRecord(
                id: 1,
                publicKey: pre.getPublicKey(),
                privateKey: pre,
              ),
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
              deviceId: bobIdentity.id,
              preKeyId: 1,
              preKeyPublic: pre.getPublicKey().serialize(),
              signedPreKeyId: 1,
              signedPreKeyPublic: signed.getPublicKey().serialize().toList(),
              signedPreKeySignature: signature.toList(),
              identityKey: bobIdentity.key.publicKey.toList(),
              kyberPreKeyId: 1,
              kyberPreKeyPublic: kp.toList(),
              kyberPreKeySignature: ks.toList(),
            );
          });
    final id = 'signal-lab-$round';
    const text = 'Локальное тестовое сообщение Signal';
    final packet = await alice.encrypt(
      id: id,
      conversation: 'signal-lab',
      recipient: bobOwner,
      recipientDevice: bobIdentity.id,
      payload: {'body': text, 'sticker': null},
      bundle: bundle,
    );
    check(
      !jsonEncode(packet).contains(text),
      'Открытого текста нет в шифропакете',
    );
    await ad.close();
    ad = await open(aliceOwner);
    alice = SignalMessageEngine(ad);
    final retry = await alice.encrypt(
      id: id,
      conversation: 'signal-lab',
      recipient: bobOwner,
      recipientDevice: bobIdentity.id,
      payload: {'sticker': null, 'body': text},
    );
    check(
      packet['ciphertext'] == retry['ciphertext'],
      'Повтор отправки использует сохранённый пакет',
    );
    final decoded = await bob.decrypt(
      id: id,
      conversation: 'signal-lab',
      sender: aliceOwner,
      senderDevice: aliceIdentity.id,
      packet: packet,
    );
    check(decoded['body'] == text, 'Получатель расшифровал сообщение');
    await bd.close();
    bd = await open(bobOwner);
    bob = SignalMessageEngine(bd);
    final history = await bob.decrypt(
      id: id,
      conversation: 'signal-lab',
      sender: aliceOwner,
      senderDevice: aliceIdentity.id,
      packet: packet,
    );
    check(
      history['body'] == text,
      'История читается после повторного открытия базы',
    );
    bool rejected = false;
    try {
      await bob.decrypt(
        id: id,
        conversation: 'signal-lab',
        sender: aliceOwner,
        senderDevice: aliceIdentity.id,
        packet: {...packet, 'ciphertext': 'invalid'},
      );
    } catch (_) {
      rejected = true;
    }
    check(rejected, 'Подмена сохранённого пакета отклонена');
    final reply = await bob.encrypt(
      id: '$id-reply',
      conversation: 'signal-lab',
      recipient: aliceOwner,
      recipientDevice: aliceIdentity.id,
      payload: {'body': 'Ответ тестового Боба'},
    );
    final answer = await alice.decrypt(
      id: '$id-reply',
      conversation: 'signal-lab',
      sender: bobOwner,
      senderDevice: bobIdentity.id,
      packet: reply,
    );
    check(
      answer['body'] == 'Ответ тестового Боба',
      'Ответ расшифрован после обновления ключей сессии',
    );
    return checks;
  } finally {
    await ad.close();
    await bd.close();
  }
}
