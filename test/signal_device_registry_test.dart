import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal/libsignal.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pulsepath/data/signal_state_database.dart';
import 'package:pulsepath/services/signal_device_registry.dart';
import 'package:pulsepath/services/signal_message_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory dir;
  String? owner;
  Future<SignalStateDatabase> open() => SignalStateDatabase.open(
    path: '${dir.path}/alice.db',
    owner: 'alice',
    currentOwner: () => owner,
  );
  setUp(() async {
    owner = 'alice';
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('pulsepath-registry-');
  });
  Map<String, dynamic> response(Map<String, dynamic> p) => {
    'user_id': 'alice',
    'device_id': p['p_device'],
    'installation_id': p['p_installation'],
    'registration_id': p['p_registration'],
    'identity_key': p['p_identity'],
    'signed_prekey': p['p_signed'],
    'revoked_at': null,
  };

  test(
    'accepted publish with lost response retries exact keys after reopening',
    () async {
      var db = await open();
      final wire = <String>[];
      Map<String, dynamic>? registered;
      var fail = true;
      Future<dynamic> rpc(String name, Map<String, dynamic> p) async {
        // A network call can open a transaction: no SQLite lock is held across RPC.
        await db.run((_, state) async => state['probe'] = true);
        wire.add(jsonEncode([name, p]));
        if (name == 'signal_register_device') return registered = response(p);
        if (name == 'signal_publish_prekeys') {
          if (fail) {
            fail = false;
            throw const SocketException('lost reply');
          }
          return 0; // already accepted; never replenish consumed IDs on retry
        }
        return [registered];
      }

      var registry = SignalDeviceRegistry(db, rpc, () => owner);
      await expectLater(
        registry.synchronize(),
        throwsA(isA<SocketException>()),
      );
      final first = await registry.prepare();
      expect(await db.run((_, s) async => s['registryConfirmed']), isNull);
      await db.close();
      db = await open();
      registry = SignalDeviceRegistry(db, rpc, () => owner);
      await registry.synchronize();
      expect(await registry.prepare(), first);
      expect(wire[0], wire[2]);
      expect(wire[1], wire[3]);
      expect(await db.run((_, s) async => s['registryConfirmed']), true);
      // Public DTO never contains private identity, EC or Kyber records.
      expect(first.keys.toSet(), {
        'installation',
        'device',
        'registration',
        'identity',
        'signed',
        'keys',
      });
      final privateIdentity = await db.run(
        (_, s) async => (s['local'] as Map)['identity'],
      );
      expect(wire.join(), isNot(contains(privateIdentity as String)));
      expect((first['keys'] as List).length, 20);
      await db.close();
    },
  );

  test(
    'wrong registration response and account switch stop publication',
    () async {
      final db = await open();
      var calls = 0;
      final registry = SignalDeviceRegistry(db, (name, p) async {
        calls++;
        return {...response(p), 'identity_key': 'wrong'};
      }, () => owner);
      await expectLater(registry.synchronize(), throwsFormatException);
      expect(calls, 1);
      final switching = SignalDeviceRegistry(db, (name, p) async {
        calls++;
        owner = 'bob';
        return response(p);
      }, () => owner);
      await expectLater(switching.synchronize(), throwsStateError);
      expect(calls, 2);
      owner = 'alice';
      expect(await db.run((_, s) async => s['registryConfirmed']), isNull);
      await db.close();
    },
  );

  test('server bundle signatures, approved identity and context protect real exchange', () async {
    final aliceDb = await open();
    final bobDb = await SignalStateDatabase.open(
      path: '${dir.path}/bob.db',
      owner: 'bob',
      currentOwner: () => 'bob',
    );
    Future<dynamic> noRpc(String n, Map<String, dynamic> p) async =>
        throw StateError('unused');
    final a = await SignalDeviceRegistry(aliceDb, noRpc, () => owner).prepare();
    final b = await SignalDeviceRegistry(bobDb, noRpc, () => 'bob').prepare();
    final key = PublicKey.deserialize(
      bytes: base64Decode(b['identity'] as String),
    );
    Map<String, dynamic> bundleJson() => jsonDecode(
      jsonEncode({
        'user_id': 'bob',
        'device_id': b['device'],
        'installation_id': b['installation'],
        'registration_id': b['registration'],
        'identity_key': b['identity'],
        'signed_prekey': b['signed'],
        'prekey': (b['keys'] as List).first,
      }),
    ) as Map<String, dynamic>;
    final bundle = SignalDeviceRegistry.parseBundle(
      bundleJson(),
      peer: 'bob',
      device: b['device'] as int,
      approvedIdentity: key,
    );
    final alice = SignalMessageEngine(aliceDb),
        bob = SignalMessageEngine(bobDb);
    await alice.approveDevice('bob', b['device'] as int, key);
    await bob.approveDevice(
      'alice',
      a['device'] as int,
      PublicKey.deserialize(bytes: base64Decode(a['identity'] as String)),
    );
    final packet = await alice.encrypt(
      id: 'one',
      conversation: 'room',
      recipient: 'bob',
      recipientDevice: b['device'] as int,
      payload: {'body': 'private'},
      bundle: bundle,
    );
    expect(
      (await bob.decrypt(
        id: 'one',
        conversation: 'room',
        sender: 'alice',
        senderDevice: a['device'] as int,
        packet: packet,
      ))['body'],
      'private',
    );
    for (final field in ['signed_prekey', 'prekey']) {
      final tampered = bundleJson();
      (tampered[field] as Map)[field == 'prekey'
          ? 'pq_signature'
          : 'signature'] = base64Encode(
        List.filled(64, 0),
      );
      expect(
        () => SignalDeviceRegistry.parseBundle(
          tampered,
          peer: 'bob',
          device: b['device'] as int,
          approvedIdentity: key,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => SignalDeviceRegistry.parseBundle(
        bundleJson(),
        peer: 'mallory',
        device: b['device'] as int,
        approvedIdentity: key,
      ),
      throwsFormatException,
    );
    expect(
      () => SignalDeviceRegistry.parseBundle(
        bundleJson(),
        peer: 'bob',
        device: b['device'] as int,
        approvedIdentity: PublicKey.deserialize(
          bytes: IdentityKeyPair.generate().publicKey.toList(),
        ),
      ),
      throwsStateError,
    );
    final bad = bundleJson();
    bad['registration_id'] = 0;
    expect(
      () => SignalDeviceRegistry.parseBundle(
        bad,
        peer: 'bob',
        device: b['device'] as int,
        approvedIdentity: key,
      ),
      throwsFormatException,
    );
    await aliceDb.close();
    await bobDb.close();
  });
}
