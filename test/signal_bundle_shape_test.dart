import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

void main() {
  test('published Signal key sizes match server validation', () async {
    await LibSignal.init();
    final identity = IdentityKeyPair.generate();
    final key = PrivateKey.generate();
    final pq = KyberKeyPair.generate();
    expect(identity.publicKey.length, 33);
    expect(key.getPublicKey().serialize().length, 33);
    expect(
      identity.sign(message: key.getPublicKey().serialize().toList()).length,
      64,
    );
    expect(pq.getPublicKey().serialize().length, 1569);
  });
}
