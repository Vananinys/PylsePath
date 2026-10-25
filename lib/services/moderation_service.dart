import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/user_scope.dart';

class ModerationStatus {
  const ModerationStatus({
    this.isModerator = false,
    this.isBanned = false,
    this.reason,
    this.expiresAt,
  });
  final bool isModerator, isBanned;
  final String? reason;
  final DateTime? expiresAt;
  factory ModerationStatus.fromJson(Map<String, dynamic> row) =>
      ModerationStatus(
        isModerator: row['is_moderator'] == true,
        isBanned: row['is_banned'] == true,
        reason: row['reason'] as String?,
        expiresAt: DateTime.tryParse(row['expires_at']?.toString() ?? ''),
      );
  String get banDescription => !isBanned
      ? ''
      : 'Публикации и комментарии ограничены ${expiresAt == null ? 'бессрочно' : 'до ${expiresAt!.toLocal().toString().substring(0, 16)}'}. Причина: ${reason ?? 'нарушение правил'}. Личные заезды доступны.';
}

class ModerationException implements Exception {
  const ModerationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ModerationService {
  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  Future<dynamic> _call(String name, [Map<String, dynamic>? params]) async {
    final owner = UserScope.currentUserId();
    if (owner == null) throw const ModerationException('Войдите в аккаунт');
    final client = _client;
    if (client == null) {
      throw const ModerationException('Нет подключения к аккаунту');
    }
    try {
      final result = await client
          .rpc(name, params: params)
          .timeout(const Duration(seconds: 12));
      if (owner != UserScope.currentUserId())
        throw const ModerationException('Аккаунт изменился');
      return result;
    } on PostgrestException catch (e) {
      if (e.message.contains('protected'))
        throw const ModerationException(
          'Себя и других модераторов заблокировать нельзя.',
        );
      if (e.code == '42501')
        throw const ModerationException('Действие доступно только модератору.');
      if (e.code == '22023')
        throw const ModerationException(
          'Проверьте причину, срок и выбранную запись.',
        );
      throw const ModerationException(
        'Не удалось выполнить действие. Обновите список и повторите.',
      );
    } catch (error) {
      // Timeout и сетевые сбои не должны показывать сырой текст исключения.
      debugPrint('[Moderation] rpc $name failed: $error');
      throw const ModerationException(
        'Не удалось выполнить действие. Обновите список и повторите.',
      );
    }
  }

  Future<ModerationStatus> status() async => ModerationStatus.fromJson(
    Map<String, dynamic>.from(
      await _call('community_moderation_status') as Map,
    ),
  );
  Future<List<Map<String, dynamic>>> list(
    String kind, {
    String query = '',
    int offset = 0,
  }) async => (await _call('community_moderation_list', {
    'p_kind': kind,
    'p_query': query,
    'p_offset': offset,
  }) as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
  Future<void> ban(String userId, {required String reason, int? hours}) async {
    await _call('moderate_community_user', {
      'p_user_id': userId,
      'p_action': 'ban',
      'p_reason': reason.trim(),
      'p_hours': hours,
    });
  }

  Future<void> unban(String userId, {required String reason}) async {
    await _call('moderate_community_user', {
      'p_user_id': userId,
      'p_action': 'unban',
      'p_reason': reason.trim(),
      'p_hours': null,
    });
  }

  Future<void> content(
    String kind,
    String id, {
    required bool hide,
    required String reason,
  }) async {
    await _call('moderate_community_content', {
      'p_kind': kind,
      'p_id': id,
      'p_action': hide ? 'hide' : 'restore',
      'p_reason': reason.trim(),
    });
  }
}
