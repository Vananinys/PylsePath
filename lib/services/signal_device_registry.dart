import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:libsignal/libsignal.dart';

import '../data/signal_state_database.dart';

typedef SignalRpc = Future<dynamic> Function(
  String name,
  Map<String, dynamic> params,
);

/// Publishes public material only, after private records have committed locally.
/// No RPC runs inside a database transaction. This does not migrate chat traffic.
class SignalDeviceRegistry {
  SignalDeviceRegistry(this.database, this.rpc, this.currentOwner);
  final SignalStateDatabase database;
  final SignalRpc rpc;
  final String? Function() currentOwner;

  void _check() {
    if (currentOwner() != database.owner) {
      throw StateError('Signal account changed');
    }
  }

  Future<dynamic> _call(String name, Map<String, dynamic> params) async {
    _check();
    final result = await rpc(name, params).timeout(const Duration(seconds: 30));
    _check();
    return result;
  }

  /// Stable installation, signed key and initial one-time batch are committed
  /// together. Reopening/retrying never generates replacements for these IDs.
  Future<Map<String, dynamic>> prepare() async {
    _check();
    if (!await database.isEnrolled()) await database.enrollNewDevice();
    return database.run((stores, state) async {
      final existing = state['publication'];
      if (existing != null) {
        return jsonDecode(jsonEncode(existing)) as Map<String, dynamic>;
      }
      final identity = await stores.getIdentityKeyPair();
      final signed = PrivateKey.generate();
      final signedPublic = signed.getPublicKey().serialize();
      final signature = identity.sign(message: signedPublic.toList());
      final now = BigInt.from(DateTime.now().millisecondsSinceEpoch);
      await stores.storeSignedPreKey(
        1,
        SignedPreKeyRecord(
          id: 1,
          publicKey: signed.getPublicKey(),
          privateKey: signed,
          signature: signature.toList(),
          timestamp: now,
        ),
      );
      final keys = <Map<String, dynamic>>[];
      for (var id = 1; id <= 20; id++) {
        final ec = PrivateKey.generate(), pq = KyberKeyPair.generate();
        final pqPublic = pq.getPublicKey().serialize();
        final pqSignature = identity.sign(message: pqPublic.toList());
        await stores.storePreKey(
          id,
          PreKeyRecord(id: id, publicKey: ec.getPublicKey(), privateKey: ec),
        );
        await stores.storeKyberPreKey(
          id,
          KyberPreKeyRecord.create(
            id: id,
            keyPair: pq,
            signature: pqSignature.toList(),
            timestamp: now,
          ),
        );
        keys.add({
          'id': id,
          'pq_id': id,
          'public_key': base64Encode(ec.getPublicKey().serialize()),
          'pq_public': base64Encode(pqPublic),
          'pq_signature': base64Encode(pqSignature),
        });
      }
      final publication = <String, dynamic>{
        'installation': newRequestId(),
        'device': state['device'],
        'registration': await stores.getLocalRegistrationId(),
        'identity': base64Encode(identity.publicKey),
        'signed': {
          'id': 1,
          'public_key': base64Encode(signedPublic),
          'signature': base64Encode(signature),
        },
        'keys': keys,
      };
      state['publication'] = publication;
      return jsonDecode(jsonEncode(publication)) as Map<String, dynamic>;
    });
  }

  /// Safe to repeat even after the server accepted a request but its reply was
  /// lost. The server retains consumed IDs, so publishing cannot resurrect keys.
  Future<void> synchronize() async {
    final p = await prepare();
    final result = await _call('signal_register_device', {
      'p_installation': p['installation'],
      'p_device': p['device'],
      'p_registration': p['registration'],
      'p_identity': p['identity'],
      'p_signed': p['signed'],
    });
    if (result is! Map ||
        result['user_id'] != database.owner ||
        result['installation_id'] != p['installation'] ||
        result['device_id'] != p['device'] ||
        result['registration_id'] != p['registration'] ||
        result['identity_key'] != p['identity'] ||
        result['revoked_at'] != null ||
        !_sameSigned(result['signed_prekey'], p['signed'])) {
      throw const FormatException('Signal registration response mismatch');
    }
    final count = await _call('signal_publish_prekeys', {
      'p_device': p['device'],
      'p_installation': p['installation'],
      'p_keys': p['keys'],
    });
    if (count is! int || count < 0 || count > (p['keys'] as List).length) {
      throw const FormatException('Signal publication response mismatch');
    }
    // Verify the server's active device against our locally held identity.
    final devices = await listDevices(database.owner);
    final mine = devices.where((d) => d['device_id'] == p['device']).toList();
    if (mine.length != 1 ||
        mine.single['revoked_at'] != null ||
        mine.single['installation_id'] != p['installation'] ||
        mine.single['identity_key'] != p['identity']) {
      throw const FormatException('Signal device registry mismatch');
    }
    await database.run((_, state) async {
      _check();
      state['registryConfirmed'] = true;
    });
  }

  Future<List<Map<String, dynamic>>> listDevices(String peer) async {
    final result = await _call('signal_list_devices', {'p_peer': peer});
    if (result is! List || result.length > 127) {
      throw const FormatException('Invalid Signal devices');
    }
    final seen = <int>{};
    return result.map((v) {
      final d = Map<String, dynamic>.from(v as Map);
      final id = _id(d['device_id'], 127);
      if (!seen.add(id) ||
          !_uuid(d['installation_id']) ||
          (d['revoked_at'] != null &&
              (d['revoked_at'] is! String ||
                  DateTime.tryParse(d['revoked_at']) == null))) {
        throw const FormatException('Invalid Signal device');
      }
      PublicKey.deserialize(bytes: _bytes(d['identity_key'], 33));
      return d;
    }).toList();
  }

  /// Caller must persist requestId before the first attempt and reuse it on
  /// network retry. Identity approval is a separate, explicit user decision.
  Future<PreKeyBundle> claimBundle({
    required String peer,
    required int device,
    required String requestId,
    required PublicKey approvedIdentity,
  }) async {
    if (!_uuid(requestId) || peer == database.owner) {
      throw ArgumentError('Invalid Signal claim');
    }
    _id(device, 127);
    final result = await _call('signal_claim_bundle', {
      'p_peer': peer,
      'p_device': device,
      'p_request': requestId,
    });
    return parseBundle(
      result,
      peer: peer,
      device: device,
      approvedIdentity: approvedIdentity,
    );
  }

  static PreKeyBundle parseBundle(
    dynamic value, {
    required String peer,
    required int device,
    required PublicKey approvedIdentity,
  }) {
    if (value is! Map ||
        value['user_id'] != peer ||
        value['device_id'] != device ||
        !_uuid(value['installation_id'])) {
      throw const FormatException('Signal bundle context mismatch');
    }
    final identityBytes = _bytes(value['identity_key'], 33);
    final identity = PublicKey.deserialize(bytes: identityBytes);
    if (!identity.equals(other: approvedIdentity)) {
      throw StateError('Signal device identity changed; verification required');
    }
    final signed = value['signed_prekey'] as Map;
    final pre = value['prekey'] as Map;
    final sp = _bytes(signed['public_key'], 33);
    final ss = _bytes(signed['signature'], 64);
    final pq = _bytes(pre['pq_public'], 1569);
    final ps = _bytes(pre['pq_signature'], 64);
    if (!identity.verify(message: sp, signature: ss) ||
        !identity.verify(message: pq, signature: ps)) {
      throw const FormatException('Signal prekey signature invalid');
    }
    return PreKeyBundle(
      registrationId: _id(value['registration_id'], 16380),
      deviceId: _id(device, 127),
      preKeyId: _id(pre['id']),
      preKeyPublic: _bytes(pre['public_key'], 33),
      signedPreKeyId: _id(signed['id']),
      signedPreKeyPublic: sp,
      signedPreKeySignature: ss,
      identityKey: identityBytes,
      kyberPreKeyId: _id(pre['pq_id']),
      kyberPreKeyPublic: pq,
      kyberPreKeySignature: ps,
    );
  }

  static bool _sameSigned(dynamic a, dynamic b) =>
      a is Map &&
      b is Map &&
      a.length == 3 &&
      a['id'] == b['id'] &&
      a['public_key'] == b['public_key'] &&
      a['signature'] == b['signature'];
  static Uint8List _bytes(dynamic v, int size) {
    if (v is! String || v.length > 4096) {
      throw const FormatException('Invalid Signal key');
    }
    final b = base64Decode(v);
    if (b.length != size || base64Encode(b) != v) {
      throw const FormatException('Invalid Signal key encoding');
    }
    return b;
  }

  static int _id(dynamic v, [int max = 2147483647]) {
    if (v is! int || v < 1 || v > max) {
      throw const FormatException('Invalid Signal key ID');
    }
    return v;
  }

  static bool _uuid(dynamic v) =>
      v is String &&
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(v);
  static String newRequestId() {
    final r = Random.secure();
    final b = List.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }
}
