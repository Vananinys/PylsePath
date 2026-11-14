import 'dart:isolate';

import 'package:flutter/services.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:libsignal/libsignal.dart';

import 'package:signal_device_check/data/signal_state_database.dart';
import 'package:signal_device_check/services/signal_message_engine.dart';
import 'package:signal_device_check/services/signal_device_registration.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'durable Signal exchange, reopen, retries, context and cached history',
    (tester) async {
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final aliceOwner = 'alice-$suffix', bobOwner = 'bob-$suffix';
      final dir = await Directory.systemTemp.createTemp(
        'pulsepath-signal-engine-',
      );
      Future<SignalStateDatabase> open(String owner) =>
          SignalStateDatabase.open(
            path: '${dir.path}/$owner.db',
            owner: owner,
            currentOwner: () => owner,
          );
      var ad = await open(aliceOwner), bd = await open(bobOwner);
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
        bobOwner,
        bi.id,
        PublicKey.deserialize(bytes: bi.key.publicKey.toList()),
      );
      await bob.approveDevice(
        aliceOwner,
        ai.id,
        PublicKey.deserialize(bytes: ai.key.publicKey.toList()),
      );
      final publication = await SignalDeviceRegistration(bd).prepare();
      SignalDeviceRegistration.verify(publication, owner: bobOwner);
      final manifest = publication['manifest'] as Map;
      final key = (publication['prekeys'] as List).first as Map;
      final claimed = <String, dynamic>{
        ...publication,
        'prekeys': [key],
      };
      SignalDeviceRegistration.verify(claimed, owner: bobOwner, claimed: true);
      final bundle = PreKeyBundle(
        registrationId: manifest['registration'] as int,
        deviceId: manifest['device'] as int,
        preKeyId: key['id'] as int,
        preKeyPublic: base64Decode(key['ec'] as String),
        signedPreKeyId: manifest['signedId'] as int,
        signedPreKeyPublic: base64Decode(manifest['signed'] as String),
        signedPreKeySignature: base64Decode(
          manifest['signedSignature'] as String,
        ),
        identityKey: base64Decode(manifest['identity'] as String),
        kyberPreKeyId: key['id'] as int,
        kyberPreKeyPublic: base64Decode(key['pq'] as String),
        kyberPreKeySignature: base64Decode(key['pqSignature'] as String),
      );
      final packet = await alice.encrypt(
        id: 'one',
        conversation: 'room',
        recipient: bobOwner,
        recipientDevice: bi.id,
        payload: {'body': 'private', 'sticker': null},
        bundle: bundle,
      );
      expect(jsonEncode(packet), isNot(contains('private')));
      await ad.close();
      ad = await open(aliceOwner);
      alice = SignalMessageEngine(ad);
      final retry = await alice.encrypt(
        id: 'one',
        conversation: 'room',
        recipient: bobOwner,
        recipientDevice: bi.id,
        payload: {'sticker': null, 'body': 'private'},
      );
      expect(retry, packet);
      await expectLater(
        alice.encrypt(
          id: 'one',
          conversation: 'room',
          recipient: bobOwner,
          recipientDevice: bi.id,
          payload: {'body': 'different'},
        ),
        throwsStateError,
      );
      expect(
        (await bob.decrypt(
          id: 'one',
          conversation: 'room',
          sender: aliceOwner,
          senderDevice: ai.id,
          packet: packet,
        ))['body'],
        'private',
      );
      await bd.close();
      bd = await open(bobOwner);
      bob = SignalMessageEngine(bd);
      final reordered = Map<String, dynamic>.fromEntries(
        packet.entries.toList().reversed,
      );
      expect(
        (await bob.decrypt(
          id: 'one',
          conversation: 'room',
          sender: aliceOwner,
          senderDevice: ai.id,
          packet: reordered,
        ))['body'],
        'private',
      );
      await expectLater(
        bob.decrypt(
          id: 'one',
          conversation: 'room',
          sender: aliceOwner,
          senderDevice: ai.id,
          packet: {...packet, 'ciphertext': 'bad'},
        ),
        throwsFormatException,
      );
      await expectLater(
        bob.decrypt(
          id: 'one',
          conversation: 'other',
          sender: aliceOwner,
          senderDevice: ai.id,
          packet: packet,
        ),
        throwsFormatException,
      );
      final reply = await bob.encrypt(
        id: 'two',
        conversation: 'room',
        recipient: aliceOwner,
        recipientDevice: ai.id,
        payload: {'body': 'reply'},
      );
      expect(
        (await alice.decrypt(
          id: 'two',
          conversation: 'room',
          sender: bobOwner,
          senderDevice: bi.id,
          packet: reply,
        ))['body'],
        'reply',
      );
      final port = ReceivePort();
      await Isolate.spawn(_encryptWorker, [
        port.sendPort,
        RootIsolateToken.instance!,
        '${dir.path}/$aliceOwner.db',
        aliceOwner,
        bobOwner,
        bi.id,
      ]);
      final foreground = <Map<String, dynamic>>[];
      for (var i = 0; i < 8; i++) {
        foreground.add(
          await alice.encrypt(
            id: 'fg-$i',
            conversation: 'room',
            recipient: bobOwner,
            recipientDevice: bi.id,
            payload: {'body': 'fg-$i'},
          ),
        );
      }
      final workerResult = await port.first.timeout(
        const Duration(seconds: 60),
      );
      port.close();
      expect(workerResult, isA<List>());
      final worker = (workerResult as List)
          .map((packet) => Map<String, dynamic>.from(packet as Map))
          .toList();
      expect(worker.length, 8);
      for (final packet in [...foreground, ...worker].reversed) {
        final id = packet['id'] as String;
        final decoded = await bob.decrypt(
          id: id,
          conversation: 'room',
          sender: aliceOwner,
          senderDevice: ai.id,
          packet: packet,
        );
        expect(decoded['body'], id);
      }
      await ad.close();
      await bd.close();
    },
  );
  testWidgets('foreground and background isolate serialize ratchet state', (
    tester,
  ) async {
    final owner = 'isolates-${DateTime.now().microsecondsSinceEpoch}';
    final dir = await Directory.systemTemp.createTemp('pulsepath-isolate-qa-');
    final path = '${dir.path}/state.db';
    final db = await SignalStateDatabase.open(
      path: path,
      owner: owner,
      currentOwner: () => owner,
    );
    await db.enrollNewDevice();
    final received = ReceivePort();
    final token = RootIsolateToken.instance!;
    await Isolate.spawn(_worker, [received.sendPort, token, path, owner]);
    for (var i = 0; i < 25; i++) {
      await db.run((_, state) async {
        final count = state['counter'] as int? ?? 0;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        state['counter'] = count + 1;
      });
    }
    final result = await received.first.timeout(const Duration(seconds: 45));
    received.close();
    expect(result, 'ok');
    expect(await db.run((_, state) async => state['counter']), 50);
    await db.close();
  });
}

Future<void> _worker(List<Object> args) async {
  final port = args[0] as SendPort;
  try {
    BackgroundIsolateBinaryMessenger.ensureInitialized(
      args[1] as RootIsolateToken,
    );
    final owner = args[3] as String;
    final db = await SignalStateDatabase.open(
      path: args[2] as String,
      owner: owner,
      currentOwner: () => owner,
    );
    for (var i = 0; i < 25; i++) {
      await db.run((_, state) async {
        final count = state['counter'] as int? ?? 0;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        state['counter'] = count + 1;
      });
    }
    await db.close();
    port.send('ok');
  } catch (e) {
    port.send('failed: ${e.runtimeType} $e');
  }
}

Future<void> _encryptWorker(List<Object> args) async {
  final port = args[0] as SendPort;
  try {
    BackgroundIsolateBinaryMessenger.ensureInitialized(
      args[1] as RootIsolateToken,
    );
    final owner = args[3] as String;
    final db = await SignalStateDatabase.open(
      path: args[2] as String,
      owner: owner,
      currentOwner: () => owner,
    );
    final engine = SignalMessageEngine(db);
    final packets = <Map<String, dynamic>>[];
    for (var i = 0; i < 8; i++) {
      packets.add(
        await engine.encrypt(
          id: 'bg-$i',
          conversation: 'room',
          recipient: args[4] as String,
          recipientDevice: args[5] as int,
          payload: {'body': 'bg-$i'},
        ),
      );
    }
    await db.close();
    port.send(packets);
  } catch (error) {
    port.send('failed: $error');
  }
}

