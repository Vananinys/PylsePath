import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Encrypted recovery container, not a messaging protocol.
/// The random recovery key must never be uploaded alongside this container.
class E2eeRecoveryVault {
  static const format = 'pulsepath-recovery-v1';
  final AesGcm _cipher = AesGcm.with256bits();

  Future<String> createRecoveryKey() async =>
      base64UrlEncode(await (await _cipher.newSecretKey()).extractBytes());

  SecretKey _key(String recoveryKey) {
    final bytes = base64Url.decode(recoveryKey.trim());
    if (bytes.length != 32) throw const FormatException('Invalid recovery key');
    return SecretKey(bytes);
  }

  List<int> _context(String owner) {
    if (owner.isEmpty) throw ArgumentError.value(owner, 'owner');
    return utf8.encode(jsonEncode([format, owner]));
  }

  Future<String> seal({
    required String owner,
    required String recoveryKey,
    required Map<String, dynamic> secrets,
  }) async {
    final plaintext = utf8.encode(jsonEncode(secrets));
    if (plaintext.length > 5 * 1024 * 1024) {
      throw const FormatException('Recovery payload too large');
    }
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: _key(recoveryKey),
      aad: _context(owner),
    );
    return jsonEncode({
      'format': format,
      'nonce': base64UrlEncode(box.nonce),
      'ciphertext': base64UrlEncode(box.cipherText),
      'mac': base64UrlEncode(box.mac.bytes),
    });
  }

  Future<Map<String, dynamic>> open({
    required String owner,
    required String recoveryKey,
    required String envelope,
  }) async {
    // Bound allocations before decoding any untrusted backup.
    if (envelope.length > 8 * 1024 * 1024) {
      throw const FormatException('Recovery container too large');
    }
    final data = jsonDecode(envelope) as Map<String, dynamic>;
    if (data['format'] != format ||
        data.length != 4 ||
        data['nonce'] is! String ||
        data['ciphertext'] is! String ||
        data['mac'] is! String) {
      throw const FormatException('Invalid recovery container');
    }
    final nonce = base64Url.decode(data['nonce'] as String);
    final mac = base64Url.decode(data['mac'] as String);
    if (nonce.length != 12 || mac.length != 16) {
      throw const FormatException('Invalid recovery parameters');
    }
    final plaintext = await _cipher.decrypt(
      SecretBox(
        base64Url.decode(data['ciphertext'] as String),
        nonce: nonce,
        mac: Mac(mac),
      ),
      secretKey: _key(recoveryKey),
      aad: _context(owner),
    );
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(plaintext)) as Map);
  }
}
