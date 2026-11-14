import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal/libsignal.dart';
import 'package:sqflite/sqflite.dart';

import 'e2ee_recovery_vault.dart';
import 'signal_protocol_stores.dart';
import 'signal_isolate_mutex.dart';

/// Signal snapshots, inbox receipts and outbox packets share one SQL transaction.
/// Database locks serialize foreground and background isolates. No network work
/// belongs inside [run]. Ciphertext/plaintext is released only after SQL commit.
class SignalStateDatabase {
  SignalStateDatabase._(this._db, this.owner, this._currentOwner, this._path);
  final Database _db;
  final String _path;
  Future<void>? _closing;
  final String owner;
  final String? Function() _currentOwner;
  static const _secure = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  final _vault = E2eeRecoveryVault();
  String get _masterKey => 'pulsepath_signal_v2_device_key_$owner';
  void _check() {
    if (_closing != null) throw StateError('Signal connection is closed');
    if (_currentOwner() != owner) throw StateError('Signal account changed');
  }

  /// Caller supplies an account-specific path excluded from OS backup.
  /// Existing snapshots are never reset automatically on decryption failure.
  static Future<SignalStateDatabase> open({
    required String path,
    required String owner,
    required String? Function() currentOwner,
  }) async {
    if (owner.isEmpty || currentOwner() != owner) {
      throw StateError('Signal owner required');
    }
    await LibSignal.init();
    final db = await SignalIsolateMutex.run(
      path,
      () => openDatabase(
        path,
        singleInstance: false,
        version: 2,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA busy_timeout=30000');
          await db.rawQuery('PRAGMA journal_mode=DELETE');
          await db.execute('PRAGMA synchronous=EXTRA');
          await db.rawQuery('PRAGMA secure_delete=ON');
        },
        onUpgrade: (db, old, _) async {
          if (old < 2) await db.execute(_recordsSchema);
        },
        onCreate: (db, _) async {
          await db.execute(_recordsSchema);
          await db.execute(
            'CREATE TABLE signal_state (id INTEGER PRIMARY KEY CHECK(id=1), envelope TEXT NOT NULL)',
          );
        },
      ),
    );
    return SignalStateDatabase._(db, owner, currentOwner, path);
  }

  static const _recordsSchema =
      'CREATE TABLE signal_records (bucket TEXT NOT NULL, id TEXT NOT NULL, envelope TEXT NOT NULL, PRIMARY KEY(bucket,id))';

  Future<T> run<T>(
    Future<T> Function(SignalProtocolStores, Map<String, dynamic>) operation,
  ) => runRecords((stores, state, _) => operation(stores, state));

  Future<T> runRecords<T>(
    Future<T> Function(
      SignalProtocolStores stores,
      Map<String, dynamic> state,
      SignalRecords records,
    )
    operation,
  ) async {
    _check();
    final result = await SignalIsolateMutex.run(
      _path,
      () => _db.transaction<T>((tx) async {
        _check();
        final rows = await tx.query('signal_state', where: 'id=1');
        final key = await _secure.read(key: _masterKey);
        _check();
        if (rows.isEmpty || key == null) {
          throw StateError('Signal device enrollment required');
        }
        final state = await _vault.open(
          owner: owner,
          recoveryKey: key,
          envelope: rows.single['envelope'] as String,
        );
        _check();
        if (state['format'] != 'pulsepath-signal-state-v2' ||
            state['owner'] != owner) {
          throw const FormatException('Signal state context mismatch');
        }
        final stores = SignalProtocolStores(state, _check);
        final records = SignalRecords._(tx, owner, key, _check);
        try {
          final output = await operation(stores, state, records);
          _check();
          final sealed = await _vault.seal(
            owner: owner,
            recoveryKey: key,
            secrets: state,
          );
          _check();
          await tx.update('signal_state', {'envelope': sealed}, where: 'id=1');
          _check();
          return output;
        } finally {
          stores.close();
          records._active = false;
        }
      }, exclusive: true),
    );
    _check();
    return result;
  }

  /// New enrollment only. Recovery restores archives and enrolls a new device;
  /// it must never rewind this live ratchet snapshot from a cloud backup.
  Future<void> enrollNewDevice() async {
    _check();
    await SignalIsolateMutex.run(
      _path,
      () => _db.transaction((tx) async {
        if ((await tx.query('signal_state')).isNotEmpty ||
            await _secure.read(key: _masterKey) != null) {
          throw StateError(
            'Signal device already exists or needs explicit recovery',
          );
        }
        _check();
        final key = await _vault.createRecoveryKey();
        final random = Random.secure();
        final identity = IdentityKeyPair.generate();
        final state = <String, dynamic>{
          'format': 'pulsepath-signal-state-v2',
          'owner': owner,
          'device': random.nextInt(127) + 1,
          'local': {
            'identity': base64Encode(identity.serialize()),
            'registration': random.nextInt(16380) + 1,
          },
        };
        final envelope = await _vault.seal(
          owner: owner,
          recoveryKey: key,
          secrets: state,
        );
        _check();
        await _secure.write(key: _masterKey, value: key);
        if (await _secure.read(key: _masterKey) != key) {
          throw StateError('Signal key write unconfirmed');
        }
        _check();
        await tx.insert('signal_state', {'id': 1, 'envelope': envelope});
        _check();
      }, exclusive: true),
    );
  }

  Future<bool> isEnrolled() async {
    _check();
    final rows = await SignalIsolateMutex.run(
      _path,
      () => _db.query('signal_state', columns: ['id'], where: 'id=1'),
    );
    _check();
    return rows.isNotEmpty;
  }

  Future<void> close() => _closing ??= SignalIsolateMutex.run(_path, _db.close);
}

/// Transaction-scoped encrypted records; IDs are authenticated with their data.
class SignalRecords {
  SignalRecords._(this._tx, this._owner, this._key, this._requireOwner);
  final Transaction _tx;
  final String _owner, _key;
  final void Function() _requireOwner;
  final _vault = E2eeRecoveryVault();
  bool _active = true;
  void _check(String bucket, String id) {
    if (!_active) throw StateError('Signal records transaction is closed');
    _requireOwner();
    if (!const ['inbox', 'outbox', 'archive'].contains(bucket) ||
        id.isEmpty ||
        id.length > 512) {
      throw ArgumentError('Invalid Signal record');
    }
  }

  String _context(String bucket, String id) => jsonEncode([_owner, bucket, id]);
  Future<Map<String, dynamic>?> read(String bucket, String id) async {
    _check(bucket, id);
    final rows = await _tx.query(
      'signal_records',
      where: 'bucket=? AND id=?',
      whereArgs: [bucket, id],
    );
    _check(bucket, id);
    if (rows.isEmpty) return null;
    final value = await _vault.open(
      owner: _context(bucket, id),
      recoveryKey: _key,
      envelope: rows.single['envelope'] as String,
    );
    _check(bucket, id);
    return value;
  }

  Future<void> write(
    String bucket,
    String id,
    Map<String, dynamic> value,
  ) async {
    _check(bucket, id);
    final sealed = await _vault.seal(
      owner: _context(bucket, id),
      recoveryKey: _key,
      secrets: value,
    );
    _check(bucket, id);
    await _tx.insert('signal_records', {
      'bucket': bucket,
      'id': id,
      'envelope': sealed,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _check(bucket, id);
  }
}
