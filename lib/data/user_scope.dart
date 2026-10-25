import 'package:supabase_flutter/supabase_flutter.dart';

/// Never automatically assign unowned legacy data to a signed-in account.
/// Legacy keys are retained for explicit, user-confirmed recovery.
class UserScope {
  const UserScope._();
  static String? currentUserId() {
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  static String keyFor(String base, String? uid) =>
      uid == null ? '${base}_guest' : '${base}_$uid';
  static Future<String> key(String base) async => keyFor(base, currentUserId());
  static Future<String> goalKey(String base) => key(base);
}
