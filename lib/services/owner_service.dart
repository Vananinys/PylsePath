import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/owner_award.dart';
import 'achievements_service.dart';
import '../data/account_progress_cache.dart';
export 'achievements_service.dart' show CatalogAchievement;

class OwnerService {
  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> entitlements() async => Map<String, dynamic>.from(
    await _client?.rpc('my_app_entitlements') ??
        <String, dynamic>{},
  );
  Future<List<CatalogAchievement>> catalog({
    bool includeInactive = false,
  }) async {
    final client = _client;
    final owner = client?.auth.currentUser?.id;
    if (client == null) return [];
    AchievementsService.bindToUser(owner);
    var query = client
        .from('achievement_catalog')
        .select('id,title,description,icon,metric,threshold,active,created_at');
    if (!includeInactive) query = query.eq('active', true);
    final cache = AccountProgressCache('achievement_catalog', owner);
    List<Map<String, dynamic>> rows;
    try {
      rows = await query
          .order('created_at')
          .timeout(const Duration(seconds: 8));
      if (!includeInactive) await cache.write(rows);
    } catch (_) {
      final saved = includeInactive ? null : await cache.read();
      if (saved is! List) rethrow;
      rows = saved.map((row) => Map<String, dynamic>.from(row as Map)).toList();
    }
    final items = rows.map((r) => CatalogAchievement(r)).toList();
    if (!includeInactive && client.auth.currentUser?.id == owner) {
      AchievementsService.catalog = List.unmodifiable(items);
    }
    return items;
  }

  Future<void> save(Map<String, dynamic> row) async {
    final client = _client;
    if (client == null) return;
    if (row['id'] == null) {
      await client
          .from('achievement_catalog')
          .insert(row)
          .timeout(const Duration(seconds: 15));
    } else {
      final data = Map<String, dynamic>.from(row)
        ..remove('id')
        ..remove('created_at');
      await client
          .from('achievement_catalog')
          .update(data)
          .eq('id', row['id'])
          .select('id')
          .single()
          .timeout(const Duration(seconds: 15));
    }
  }

  Future<List<Map<String, dynamic>>> titles({
    bool includeInactive = false,
  }) async {
    final client = _client;
    if (client == null) return [];
    var query = client
        .from('title_catalog')
        .select('id,title,description,icon,active,created_at');
    if (!includeInactive) query = query.eq('active', true);
    final rows = await query
        .order('created_at')
        .timeout(const Duration(seconds: 12));
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> saveTitle(Map<String, dynamic> row) async {
    final client = _client;
    if (client == null) return;
    if (row['id'] == null) {
      await client
          .from('title_catalog')
          .insert(row)
          .timeout(const Duration(seconds: 15));
    } else {
      final data = Map<String, dynamic>.from(row)
        ..remove('id')
        ..remove('created_at');
      await client
          .from('title_catalog')
          .update(data)
          .eq('id', row['id'])
          .select('id')
          .single()
          .timeout(const Duration(seconds: 15));
    }
  }

  Future<List<OwnerAward>> awards() async {
    final client = _client;
    final owner = client?.auth.currentUser?.id;
    if (owner == null || client == null) return [];
    final cache = AccountProgressCache('owner_awards', owner);
    List<Map<String, dynamic>> rows;
    try {
      rows = await client
          .from('user_owner_awards')
          .select('id,kind,award_key,label,icon,equipped,granted_at')
          .eq('user_id', owner)
          .order('granted_at', ascending: false)
          .timeout(const Duration(seconds: 8));
      await cache.write(rows);
    } catch (_) {
      final saved = await cache.read();
      if (saved is! List) rethrow;
      rows = saved.map((row) => Map<String, dynamic>.from(row as Map)).toList();
    }
    if (client.auth.currentUser?.id != owner) return [];
    return rows
        .map((row) => OwnerAward.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<void> grant({
    required String kind,
    required String key,
    required String label,
    required String icon,
  }) async {
    final client = _client;
    if (client == null) return;
    if (key.startsWith('builtin:')) {
      await client
          .rpc(
            'owner_manage_award',
            params: {
              'p_action': 'grant',
              'p_kind': kind,
              'p_key': key,
              'p_label': label,
              'p_icon': icon,
              'p_award_id': null,
            },
          )
          .timeout(const Duration(seconds: 15));
      return;
    }
    await manageRecipients(
      action: 'grant',
      kind: kind,
      key: key,
      userId: client.auth.currentUser!.id,
    );
  }

  Future<List<Map<String, dynamic>>> rewardUsers([String query = '']) async =>
      (await _client
              ?.rpc(
                'owner_reward_users',
                params: {'p_query': query},
              )
              .timeout(const Duration(seconds: 12)) ??
          const <Map<String, dynamic>>[])
          .map((row) => Map<String, dynamic>.from(row))
          .toList();

  Future<List<Map<String, dynamic>>> builtinAwards() async =>
      (await _client
                  ?.rpc('owner_builtin_awards')
                  .timeout(const Duration(seconds: 8)) ??
              const [])
          .map(
            (row) => <String, dynamic>{
              ...Map<String, dynamic>.from(row),
              'kind': 'achievement',
              'key': row['award_key'],
              'title': row['label'],
              'builtin': true,
            },
          )
          .toList();

  Future<List<Map<String, dynamic>>> recipientAwards(String userId) async =>
      (await _client
              ?.from('user_owner_awards')
              .select()
              .eq('user_id', userId)
              .order('granted_at', ascending: false)
              .timeout(const Duration(seconds: 12)) ??
          const [])
          .map((row) => Map<String, dynamic>.from(row))
          .toList();

  Future<int> manageRecipients({
    required String action,
    required String kind,
    required String key,
    String? userId,
    bool all = false,
    String reason = '',
  }) async =>
      ((await _client
              ?.rpc(
                'owner_award_users',
                params: {
                  'p_action': action,
                  'p_kind': kind,
                  'p_key': key,
                  'p_user_id': userId,
                  'p_all': all,
                  'p_reason': reason,
                },
              )
              .timeout(const Duration(seconds: 20))) as num? ?? -1)
          .toInt();

  Future<List<Map<String, dynamic>>> awardHistory() async =>
      (await _client
              ?.rpc('owner_award_history_details')
              .timeout(const Duration(seconds: 12)) ??
          const [])
          .map((row) => Map<String, dynamic>.from(row))
          .toList();

  Future<void> grantTitle(String id) async {
    await manageRecipients(
      action: 'grant',
      kind: 'title',
      key: id,
      userId: _client?.auth.currentUser?.id,
    );
  }

  Future<void> revoke(String id) async {
    final client = _client;
    final owner = client?.auth.currentUser?.id;
    if (client == null || owner == null) return;
    final award = await client
        .from('user_owner_awards')
        .select('kind,award_key')
        .eq('id', id)
        .eq('user_id', owner)
        .single()
        .timeout(const Duration(seconds: 12));
    if (client.auth.currentUser?.id != owner)
      throw StateError('Account changed');
    await manageRecipients(
      action: 'revoke',
      kind: award['kind'] as String,
      key: award['award_key'] as String,
      userId: owner,
    );
  }
}
