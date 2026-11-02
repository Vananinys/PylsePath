import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/user_scope.dart';

class CommunityInboxService {
  Future<List<Map<String, dynamic>>> unread() async {
    final owner = UserScope.currentUserId();
    if (owner == null) return [];
    final rows = await Supabase.instance.client
        .from('community_notifications')
        .select()
        .eq('recipient_id', owner)
        .isFilter('read_at', null)
        .order('created_at', ascending: false)
        .limit(50).timeout(const Duration(seconds: 12));
    if (UserScope.currentUserId() != owner) return [];
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<void> markRead(String id) async {
    final owner = UserScope.currentUserId();
    if (owner == null) return;
    await Supabase.instance.client
        .from('community_notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', id)
        .eq('recipient_id', owner).timeout(const Duration(seconds: 12));
  }
}
