import 'dart:convert';

import 'package:libsignal/libsignal.dart';

/// Transaction-scoped protocol callbacks. The caller must atomically commit
/// the complete snapshot with its outbox/inbox before releasing any output.
/// Never keep this adapter alive across a transaction or use it as a cache.
class SignalProtocolStores
    implements
        SessionStore,
        IdentityKeyStore,
        PreKeyStore,
        SignedPreKeyStore,
        KyberPreKeyStore {
  SignalProtocolStores(this._state, this._requireOwner);
  final Map<String, dynamic> _state;
  final void Function() _requireOwner;
  bool _active = true;
  void close() => _active = false;
  void _check() {
    if (!_active) throw StateError('Signal transaction is closed');
    _requireOwner();
  }

  Map<String, dynamic> _bucket(String name) {
    _check();
    return (_state.putIfAbsent(name, () => <String, dynamic>{}) as Map)
        .cast<String, dynamic>();
  }

  String _address(ProtocolAddress address) =>
      jsonEncode([address.name(), address.deviceId()]);
  List<int>? _bytes(String bucket, String key) {
    final value = _bucket(bucket)[key] as String?;
    return value == null ? null : base64Decode(value);
  }

  void _put(String bucket, String key, List<int> bytes) =>
      _bucket(bucket)[key] = base64Encode(bytes);
  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    final bytes = _bytes('local', 'identity');
    if (bytes == null) throw StateError('Signal device is not initialized');
    return IdentityKeyPair.deserialize(bytes: bytes);
  }

  @override
  Future<int> getLocalRegistrationId() async =>
      _bucket('local')['registration'] as int;
  @override
  Future<PublicKey?> getIdentity(ProtocolAddress address) async {
    final bytes = _bytes('pins', _address(address));
    return bytes == null ? null : PublicKey.deserialize(bytes: bytes);
  }

  @override
  Future<bool> saveIdentity(
    ProtocolAddress address,
    PublicKey identityKey,
  ) async {
    final previous = await getIdentity(address);
    _check();
    if (previous != null && !previous.equals(other: identityKey)) {
      throw StateError(
        'Signal device identity changed; explicit verification required',
      );
    }
    _put('pins', _address(address), identityKey.serialize());
    return previous == null;
  }

  @override
  Future<bool> isTrustedIdentity(
    ProtocolAddress address,
    PublicKey key,
    Direction direction,
  ) async {
    final previous = await getIdentity(address);
    _check();
    return previous == null || previous.equals(other: key);
  }

  @override
  Future<SessionRecord?> loadSession(ProtocolAddress address) async {
    final bytes = _bytes('sessions', _address(address));
    return bytes == null ? null : SessionRecord.deserialize(bytes: bytes);
  }

  @override
  Future<void> storeSession(
    ProtocolAddress address,
    SessionRecord record,
  ) async => _put('sessions', _address(address), record.serialize());
  @override
  Future<bool> containsSession(ProtocolAddress address) async =>
      _bucket('sessions').containsKey(_address(address));
  @override
  Future<void> deleteSession(ProtocolAddress address) async =>
      _bucket('sessions').remove(_address(address));
  @override
  Future<void> deleteAllSessions(String name) async =>
      _bucket('sessions')
          .removeWhere((key, _) => (jsonDecode(key) as List).first == name);
  @override
  Future<List<int>> getSubDeviceSessions(String name) async =>
      _bucket('sessions').keys
          .map((key) => jsonDecode(key) as List)
          .where((a) => a.first == name)
          .map((a) => a[1] as int)
          .toList();
  @override
  Future<PreKeyRecord?> loadPreKey(int id) async {
    final bytes = _bytes('prekeys', '$id');
    return bytes == null ? null : PreKeyRecord.deserialize(bytes: bytes);
  }

  @override
  Future<void> storePreKey(int id, PreKeyRecord record) async =>
      _put('prekeys', '$id', record.serialize());
  @override
  Future<bool> containsPreKey(int id) async =>
      _bucket('prekeys').containsKey('$id');
  @override
  Future<void> removePreKey(int id) async => _bucket('prekeys').remove('$id');
  @override
  Future<List<int>> getAllPreKeyIds() async =>
      _bucket('prekeys').keys.map(int.parse).toList();
  @override
  Future<SignedPreKeyRecord?> loadSignedPreKey(int id) async {
    final bytes = _bytes('signed', '$id');
    return bytes == null ? null : SignedPreKeyRecord.deserialize(bytes: bytes);
  }

  @override
  Future<void> storeSignedPreKey(int id, SignedPreKeyRecord record) async =>
      _put('signed', '$id', record.serialize());
  @override
  Future<bool> containsSignedPreKey(int id) async =>
      _bucket('signed').containsKey('$id');
  @override
  Future<void> removeSignedPreKey(int id) async =>
      _bucket('signed').remove('$id');
  @override
  Future<List<int>> getAllSignedPreKeyIds() async =>
      _bucket('signed').keys.map(int.parse).toList();
  @override
  Future<KyberPreKeyRecord?> loadKyberPreKey(int id) async {
    final bytes = _bytes('kyber', '$id');
    return bytes == null ? null : KyberPreKeyRecord.deserialize(bytes: bytes);
  }

  @override
  Future<void> storeKyberPreKey(int id, KyberPreKeyRecord record) async =>
      _put('kyber', '$id', record.serialize());
  @override
  Future<bool> containsKyberPreKey(int id) async =>
      _bucket('kyber').containsKey('$id');
  @override
  Future<bool> markKyberPreKeyUsed(
    int id,
    int signedId,
    PublicKey baseKey,
  ) async {
    final key = jsonEncode([id, signedId, base64Encode(baseKey.serialize())]);
    final seen = _bucket('agreements');
    if (seen.containsKey(key)) return false;
    // V2 uses one-time PQ prekeys only; last-resort reuse is not enabled.
    if (_bucket('usedKyber').containsKey('$id')) return false;
    seen[key] = true;
    _bucket('usedKyber')['$id'] = true;
    return true;
  }

  @override
  Future<void> removeKyberPreKey(int id) async {
    _bucket('kyber').remove('$id');
    // Keep the tombstone: deleting a private key must never undo replay state.
  }

  @override
  Future<List<int>> getAllKyberPreKeyIds() async =>
      _bucket('kyber').keys.map(int.parse).toList();
}
