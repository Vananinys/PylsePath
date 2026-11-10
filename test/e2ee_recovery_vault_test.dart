import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/data/e2ee_recovery_vault.dart';

void main() {
  test(
    'restores secrets on another instance without server plaintext',
    () async {
      final vault = E2eeRecoveryVault();
      final key = await vault.createRecoveryKey();
      final sealed = await vault.seal(
        owner: 'alice',
        recoveryKey: key,
        secrets: {
          'identity': 'private-identity',
          'sessions': ['private-session'],
        },
      );
      expect(sealed, isNot(contains('private-identity')));
      expect(sealed, isNot(contains('private-session')));
      expect(sealed, isNot(contains(key)));
      expect(
        await E2eeRecoveryVault().open(
          owner: 'alice',
          recoveryKey: key,
          envelope: sealed,
        ),
        {
          'identity': 'private-identity',
          'sessions': ['private-session'],
        },
      );
    },
  );

  test('rejects another account, wrong key and modified ciphertext', () async {
    final vault = E2eeRecoveryVault();
    final key = await vault.createRecoveryKey();
    final sealed = await vault.seal(
      owner: 'alice',
      recoveryKey: key,
      secrets: {'identity': 'secret'},
    );
    await expectLater(
      vault.open(owner: 'bob', recoveryKey: key, envelope: sealed),
      throwsA(anything),
    );
    await expectLater(
      vault.open(
        owner: 'alice',
        recoveryKey: await vault.createRecoveryKey(),
        envelope: sealed,
      ),
      throwsA(anything),
    );
    final data = jsonDecode(sealed) as Map<String, dynamic>;
    final bytes = base64Url.decode(data['ciphertext'] as String);
    bytes[0] ^= 1;
    data['ciphertext'] = base64UrlEncode(bytes);
    await expectLater(
      vault.open(owner: 'alice', recoveryKey: key, envelope: jsonEncode(data)),
      throwsA(anything),
    );
  });

  test('fresh nonces prevent repeated backups from matching', () async {
    final vault = E2eeRecoveryVault();
    final key = await vault.createRecoveryKey();
    Future<String> seal() => vault.seal(
      owner: 'alice',
      recoveryKey: key,
      secrets: {'identity': 'secret'},
    );
    expect(await seal(), isNot(await seal()));
  });
}
