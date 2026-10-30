import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/user_scope.dart';

class EventsService {
  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    final owner = UserScope.currentUserId();
    if (owner == null) throw StateError('Войдите в аккаунт');
    final result = await Supabase.instance.client
        .rpc('events_action', params: {'p_action': action, 'p_data': data})
        .timeout(const Duration(seconds: 15));
    if (owner != UserScope.currentUserId())
      throw StateError('Аккаунт изменился');
    final response = Map<String, dynamic>.from(result as Map);
    if (action == 'list') {
      final rewards = await Supabase.instance.client
          .from('app_event_rewards')
          .select('xp,badge,issued_at')
          .eq('user_id', owner)
          .order('issued_at', ascending: false)
          .limit(100)
          .timeout(const Duration(seconds: 10));
      if (owner != UserScope.currentUserId())
        throw StateError('Аккаунт изменился');
      response['rewards'] = rewards;
    }
    return response;
  }
}
