import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/secure_session_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const legacy = 'sb-nhxlpfbiskaqahnkrmtx-auth-token';
  test('migrates existing login, persists refresh, and logout cannot resurrect old session', () async {
    SharedPreferences.setMockInitialValues({
      legacy: 'old-session',
      'history': 'keep',
    });
    FlutterSecureStorage.setMockInitialValues({});
    final store = SecureSessionStorage();
    await store.initialize();
    expect(await store.accessToken(), 'old-session');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(legacy), isNull);
    expect(prefs.getString('history'), 'keep');
    await store.persistSession('refreshed');
    final background = SecureSessionStorage();
    await background.initialize();
    expect(await background.accessToken(), 'refreshed');
    await store.removePersistedSession();
    await background.initialize();
    expect(await background.hasAccessToken(), isFalse);
  });
  test('existing secure session wins over stale legacy copy', () async {
    SharedPreferences.setMockInitialValues({legacy: 'stale'});
    FlutterSecureStorage.setMockInitialValues({'secure_$legacy': 'current'});
    final store = SecureSessionStorage();
    await store.initialize();
    expect(await store.accessToken(), 'current');
  });
}
