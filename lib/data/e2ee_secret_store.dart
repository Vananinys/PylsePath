import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Account-scoped protocol secrets. No SharedPreferences/plaintext fallback.
/// Not connected to the production chat until protocol rollout is complete.
class E2eeSecretStore {
  E2eeSecretStore({
    required this.owner,
    required this.currentOwner,
    Future<String?> Function(String)? read,
    Future<void> Function(String, String)? write,
  }) : _read = read ?? ((key) => _storage.read(key: key)),
       _write =
           write ?? ((key, value) => _storage.write(key: key, value: value)) {
    if (owner.isEmpty) throw ArgumentError.value(owner, 'owner');
  }

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  final String owner;
  final String? Function() currentOwner;
  final Future<String?> Function(String) _read;
  final Future<void> Function(String, String) _write;
  Future<void> _tail = Future.value();
  String get _key =>
      'pulsepath_e2ee_secrets_v1_${base64UrlEncode(utf8.encode(owner))}';

  void _requireOwner() {
    if (currentOwner() != owner) {
      throw StateError('Аккаунт изменился. Откройте защищённый чат заново.');
    }
  }

  Future<Map<String, dynamic>?> read() async {
    await _tail;
    _requireOwner();
    final raw = await _read(_key);
    _requireOwner();
    if (raw == null) return null;
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  /// Writes one key snapshot; a failed secure write propagates to caller.
  /// Readback is not an fsync guarantee. This is NOT a durable ratchet store;
  /// session state requires a separate atomic, durable transaction layer.
  Future<void> save(Map<String, dynamic> secrets) {
    final raw = jsonEncode(secrets);
    final operation = _tail.then((_) async {
      _requireOwner();
      await _write(_key, raw);
      _requireOwner();
      if (await _read(_key) != raw) {
        throw StateError('Не удалось подтвердить сохранение ключей шифрования');
      }
      _requireOwner();
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }
}
