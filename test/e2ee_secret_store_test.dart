import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/data/e2ee_secret_store.dart';

void main() {
  test('account snapshots remain isolated and survive reopening', () async {
    var account = 'alice';
    final disk = <String, String>{};
    E2eeSecretStore store(String owner) => E2eeSecretStore(
      owner: owner,
      currentOwner: () => account,
      read: (key) async => disk[key],
      write: (key, value) async {
        disk[key] = value;
      },
    );
    await store('alice').save({'identity': 'alice-private'});
    account = 'bob';
    expect(await store('bob').read(), isNull);
    await store('bob').save({'identity': 'bob-private'});
    await expectLater(store('alice').read(), throwsStateError);
    account = 'alice';
    expect(await store('alice').read(), {'identity': 'alice-private'});
  });

  test(
    'does not return secrets when account switches during storage read',
    () async {
      var account = 'alice';
      final pending = Completer<String?>();
      final store = E2eeSecretStore(
        owner: account,
        currentOwner: () => account,
        read: (_) => pending.future,
        write: (_, __) async {},
      );
      final reading = store.read();
      await Future<void>.delayed(Duration.zero);
      account = 'bob';
      pending.complete('{"identity":"alice-private"}');
      await expectLater(reading, throwsStateError);
    },
  );

  test(
    'failed secure write cannot silently pass or poison the next save',
    () async {
      String? raw;
      var fail = true;
      final store = E2eeSecretStore(
        owner: 'alice',
        currentOwner: () => 'alice',
        read: (_) async => raw,
        write: (_, value) async {
          if (fail) throw StateError('keystore unavailable');
          raw = value;
        },
      );
      await expectLater(store.save({'session': 1}), throwsStateError);
      expect(raw, isNull);
      fail = false;
      await store.save({'session': 2});
      expect(await store.read(), {'session': 2});
    },
  );

  test('unconfirmed writes are rejected', () async {
    final store = E2eeSecretStore(
      owner: 'alice',
      currentOwner: () => 'alice',
      read: (_) async => null,
      write: (_, __) async {},
    );
    await expectLater(store.save({'identity': 'secret'}), throwsStateError);
  });
}
