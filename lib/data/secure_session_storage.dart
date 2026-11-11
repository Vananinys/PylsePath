import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';

/// Both foreground and background Supabase initialization use the same store.
class SecureSessionStorage extends LocalStorage {
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  String get _legacy =>
      'sb-${Uri.parse(AppConfig.supabaseUrl).host.split('.').first}-auth-token';
  String get _key => 'secure_$_legacy';
  @override
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final legacy = prefs.getString(_legacy);
    if (legacy != null && await _storage.read(key: _key) == null) {
      await _storage.write(key: _key, value: legacy);
      if (await _storage.read(key: _key) != legacy) {
        throw StateError('Session migration could not be verified');
      }
    }
    // Delete only the migrated session copy, never history or identity keys.
    if (legacy != null) await prefs.remove(_legacy);
  }

  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;
  @override
  Future<String?> accessToken() => _storage.read(key: _key);
  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _key, value: persistSessionString);
  @override
  Future<void> removePersistedSession() async {
    await _storage.delete(key: _key);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacy);
  }
}

LocalStorage? platformSessionStorage() =>
    kIsWeb ? null : SecureSessionStorage();
