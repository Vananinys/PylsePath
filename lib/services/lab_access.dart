import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/user_scope.dart';

class LabAccess {
  static Future<Map<String, dynamic>> check() async {
    final owner = UserScope.currentUserId();
    if (owner == null) return {'can_simulate': false, 'is_owner': false};
    final data = await Supabase.instance.client
        .rpc('my_lab_access')
        .timeout(const Duration(seconds: 10));
    if (owner != UserScope.currentUserId()) throw StateError('Account changed');
    return Map<String, dynamic>.from(data as Map);
  }
}
