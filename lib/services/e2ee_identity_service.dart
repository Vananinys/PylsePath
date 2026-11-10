import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/e2ee_recovery_vault.dart';
import '../data/e2ee_secret_store.dart';
import 'e2ee_box_codec.dart';

class E2eeException implements Exception {
  const E2eeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Account identity shared with another installation only via the user's
/// recovery key. No private seed or recovery key is uploaded unencrypted.
class E2eeIdentityService {
  static final _instances = Expando<Map<String, E2eeIdentityService>>();
  factory E2eeIdentityService(SupabaseClient client, String owner) =>
      (_instances[client] ??= {}).putIfAbsent(
        owner,
        () => E2eeIdentityService._(client, owner),
      );
  E2eeIdentityService._(this.client, this.owner)
    : store = E2eeSecretStore(
        owner: owner,
        currentOwner: () => client.auth.currentUser?.id,
      );
  final SupabaseClient client;
  final String owner;
  final E2eeSecretStore store;
  static final Future<Sodium> _runtime = Future.sync(SodiumInit.init);
  Future<void> _tail = Future.value();
  Map<String, dynamic>? _cached;
  void resetMemory() {
    _cached = null;
  }

  void _requireOwner() {
    if (client.auth.currentUser?.id != owner) {
      throw const E2eeException('Аккаунт изменился. Откройте чат заново.');
    }
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final task = _tail.then((_) async {
      _requireOwner();
      final value = await operation();
      _requireOwner();
      return value;
    });
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  Future<Map<String, dynamic>?> _published(String user) async {
    final row = await client
        .from('e2ee_identities')
        .select('public_key')
        .eq('user_id', user)
        .maybeSingle()
        .timeout(const Duration(seconds: 15));
    _requireOwner();
    return row;
  }

  KeyPair _pair(Sodium sodium, Map<String, dynamic> secrets) {
    final seed = sodium.secureCopy(base64Url.decode(secrets['seed'] as String));
    try {
      return sodium.crypto.box.seedKeyPair(seed);
    } finally {
      seed.dispose();
    }
  }

  Future<Map<String, dynamic>> _ensure() async {
    _requireOwner();
    if (_cached != null) return _cached!;
    final sodium = await _runtime;
    final local = await store.read();
    if (local != null && local['published'] is String) {
      final existingPair = _pair(sodium, local);
      try {
        if (local['published'] == base64UrlEncode(existingPair.publicKey)) {
          _cached = local;
          return local; // Registered local keys and pinned peers also work offline.
        }
      } finally {
        existingPair.secretKey.dispose();
      }
    }
    final published = await _published(owner);
    if (local == null && published != null) {
      throw const E2eeException(
        'На этом устройстве нет ключа переписки. Восстановите его личным ключом в настройках конфиденциальности.',
      );
    }
    final secrets =
        local ??
        {
          'seed': base64UrlEncode(
            sodium.randombytes.buf(sodium.crypto.box.seedBytes),
          ),
          'recovery': await E2eeRecoveryVault().createRecoveryKey(),
          'pins': <String, dynamic>{},
        };
    final pair = _pair(sodium, secrets);
    try {
      final public = base64UrlEncode(pair.publicKey);
      if (published != null && published['public_key'] != public) {
        throw const E2eeException(
          'Ключ аккаунта не совпадает. Отправка заблокирована до восстановления исходного ключа.',
        );
      }
      if (local == null) await store.save(secrets);
      if (published == null) {
        final backup = await E2eeRecoveryVault().seal(
          owner: owner,
          recoveryKey: secrets['recovery'] as String,
          secrets: {'seed': secrets['seed']},
        );
        _requireOwner();
        await client
            .rpc(
              'e2ee_register_identity',
              params: {'p_public_key': public, 'p_backup': backup},
            )
            .timeout(const Duration(seconds: 15));
        _requireOwner();
      }
      secrets['published'] = public;
      await store.save(secrets);
      _cached = secrets;
      return secrets;
    } finally {
      pair.secretKey.dispose();
    }
  }

  Future<void> ensure() => _serial(() async {
    await _ensure();
  });

  Future<String> exportRecoveryKey() =>
      _serial(() async => (await _ensure())['recovery'] as String);

  Future<void> restore(String recoveryKey) => _serial(() async {
    final row = await client
        .from('e2ee_recovery_backups')
        .select('envelope')
        .eq('user_id', owner)
        .single()
        .timeout(const Duration(seconds: 15));
    _requireOwner();
    final recovered = await E2eeRecoveryVault().open(
      owner: owner,
      recoveryKey: recoveryKey,
      envelope: row['envelope'] as String,
    );
    final sodium = await _runtime;
    final pair = _pair(sodium, recovered);
    try {
      final published = await _published(owner);
      if (published?['public_key'] != base64UrlEncode(pair.publicKey)) {
        throw const E2eeException(
          'Ключ восстановления не соответствует аккаунту.',
        );
      }
      final previous = await store.read();
      if (previous != null && previous['seed'] != recovered['seed']) {
        final previousPair = _pair(sodium, previous);
        try {
          if (published?['public_key'] ==
              base64UrlEncode(previousPair.publicKey)) {
            throw const E2eeException(
              'На устройстве уже действующий ключ. Замена запрещена.',
            );
          }
          // A locally generated seed may have lost a simultaneous registration.
          // A verified recovery of the published identity can replace that provisional seed.
        } finally {
          previousPair.secretKey.dispose();
        }
      }
      await store.save({
        'seed': recovered['seed'],
        'recovery': recoveryKey.trim(),
        'published': base64UrlEncode(pair.publicKey),
        'pins': previous?['pins'] ?? <String, dynamic>{},
      });
      _cached = null;
    } finally {
      pair.secretKey.dispose();
    }
  });

  Future<Uint8List> _peer(String user, Map<String, dynamic> secrets) async {
    final pinned = (secrets['pins'] as Map)[user];
    if (pinned is String) return base64Url.decode(pinned);
    final row = await _published(user);
    if (row == null) {
      throw const E2eeException(
        'Собеседнику нужно обновить PulsePath и открыть приложение для создания ключа. Открытая отправка запрещена.',
      );
    }
    final public = row['public_key'] as String;
    final pins = Map<String, dynamic>.from(secrets['pins'] as Map);
    if (pins.containsKey(user) && pins[user] != public) {
      throw const E2eeException(
        'Ключ собеседника изменился. Отправка и расшифровка заблокированы.',
      );
    }
    final bytes = base64Url.decode(public);
    if (bytes.length != 32) throw const FormatException('Invalid identity key');
    if (!pins.containsKey(user)) {
      pins[user] = public;
      secrets['pins'] = pins;
      await store.save(secrets);
    }
    return bytes;
  }

  Future<Map<String, dynamic>> encrypt({
    required String id,
    required String conversation,
    required Iterable<String> recipients,
    required Map<String, dynamic> payload,
  }) => _serial(() async {
    final secrets = await _ensure();
    final sodium = await _runtime;
    final pair = _pair(sodium, secrets);
    try {
      final keys = <String, Uint8List>{owner: pair.publicKey};
      for (final user in recipients.toSet()..remove(owner)) {
        keys[user] = await _peer(user, secrets);
      }
      _requireOwner();
      return E2eeBoxCodec(sodium).encrypt(
        id: id,
        sender: owner,
        conversation: conversation,
        senderSecret: pair.secretKey,
        recipients: keys,
        payload: payload,
      );
    } finally {
      pair.secretKey.dispose();
    }
  });

  Future<Map<String, dynamic>> decrypt({
    required String id,
    required String sender,
    required String conversation,
    required Map<String, dynamic> envelope,
  }) => _serial(() async {
    final secrets = await _ensure();
    final sodium = await _runtime;
    final pair = _pair(sodium, secrets);
    try {
      final public = sender == owner
          ? pair.publicKey
          : await _peer(sender, secrets);
      _requireOwner();
      return E2eeBoxCodec(sodium).decrypt(
        envelope: envelope,
        id: id,
        sender: sender,
        conversation: conversation,
        recipient: owner,
        senderPublic: public,
        recipientSecret: pair.secretKey,
      );
    } finally {
      pair.secretKey.dispose();
    }
  });

  Future<Map<String, String>> fingerprints(String? peer) => _serial(() async {
    final secrets = await _ensure();
    final sodium = await _runtime;
    final pair = _pair(sodium, secrets);
    try {
      String fingerprint(Uint8List bytes) =>
          hashes.sha256.convert(bytes).toString();
      return {
        'own': fingerprint(pair.publicKey),
        if (peer != null) 'peer': fingerprint(await _peer(peer, secrets)),
      };
    } finally {
      pair.secretKey.dispose();
    }
  });
}
