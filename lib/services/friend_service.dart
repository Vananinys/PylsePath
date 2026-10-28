import '../data/ui_snapshot_cache.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/live_trail_style.dart';

import 'package:latlong2/latlong.dart' hide Path;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/friend_profile.dart';

/// Ошибка сервиса сообщества с готовым для UI текстом.
class FriendServiceException implements Exception {
  const FriendServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Сообщество: друзья, заявки в друзья, поиск райдеров и живые позиции
/// друзей на карте (Supabase Realtime, таблица `live_positions`).
///
/// Схема (см. миграцию v1.0):
///  - `public_profiles` — публичная проекция профилей (без веса/роста/возраста);
///  - `friends (user_id, friend_id)` — симметричные пары;
///  - `friend_requests (from_user, to_user)`;
///  - `live_positions (user_id, latitude, longitude, updated_at)`.
///
/// Важно: выборки строятся В ДВЕ СТУПЕНИ (строки → профили пакетом по id).
/// Embedded-запросы (select с `public_profiles!..._fkey`) здесь не работают:
/// FK таблиц друзей/заявок указывает на auth.users, а `public_profiles` —
/// view без внешних ключей, PostgREST отклоняет такое встраивание, и список
/// молча приходил пустым.
class FriendService {
  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  static bool get isAvailable => _client != null;

  String? get userId => _client?.auth.currentUser?.id;

  Future<Map<String, dynamic>?> fetchPublicTitle(String userId) async {
    final client = _client;
    if (client == null) return null;
    final row = await client
        .from('public_profile_titles')
        .select('label,icon')
        .eq('user_id', userId)
        .maybeSingle()
        .timeout(const Duration(seconds: 12));
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  RealtimeChannel? _positionsChannel;

  // ── Друзья ────────────────────────────────────────────────────────────

  Future<List<FriendProfile>?> loadCachedFriends() async {
    final owner = userId;
    if (owner == null) return null;
    final rows = await UiSnapshotCache('friends', owner).read(allowStale: true);
    if (userId != owner || rows == null) return null;
    try {
      return rows.map(FriendProfile.fromRow).toList();
    } catch (_) {
      return null;
    }
  }

  /// Список друзей с публичными профилями и живыми позициями.
  Future<List<FriendProfile>> fetchFriends() async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return const [];

    try {
      final rows = await client
          .from('friends')
          .select('friend_id')
          .eq('user_id', id)
          .timeout(const Duration(seconds: 12));

      final friendIds = rows
          .map(
            (raw) => (Map<String, dynamic>.from(raw))['friend_id']?.toString(),
          )
          .whereType<String>()
          .toList();
      if (friendIds.isEmpty) {
        if (userId == id) await UiSnapshotCache('friends', id).write([]);
        return const [];
      }

      final profiles = await client
          .from('public_profiles')
          .select(
            'id, username, avatar_url, status, city, '
            'preferred_riding_type, weight, age, gender',
          )
          .inFilter('id', friendIds)
          .timeout(const Duration(seconds: 12));

      final liveRows = await client
          .from('live_positions')
          .select()
          .inFilter('user_id', friendIds)
          .timeout(const Duration(seconds: 12));
      final liveByUser = <String, Map<String, dynamic>>{
        for (final raw in liveRows) ((raw)['user_id'] ?? '').toString(): raw,
      };
      final stylesByUser = <String, Map<String, dynamic>>{};
      try {
        final styles = await client
            .from('profile_trail_styles')
            .select()
            .inFilter('user_id', friendIds)
            .timeout(const Duration(seconds: 6));
        for (final row in styles) {
          stylesByUser[row['user_id'].toString()] = Map<String, dynamic>.from(
            row,
          );
        }
      } catch (_) {
        /* A cosmetics outage must not hide friends or positions. */
      }

      if (userId != id) return const [];
      await UiSnapshotCache('friends', id).write(
        profiles
            .map(
              (row) => <String, dynamic>{
                'id': row['id'],
                'username': row['username'],
                'avatar_url': row['avatar_url'],
                'status': row['status'],
                'city': row['city'],
                'preferred_riding_type': row['preferred_riding_type'],
              },
            )
            .toList(),
      );
      if (userId != id) return const [];
      return profiles.map((raw) {
        final data = Map<String, dynamic>.from(raw);
        final live = liveByUser[data['id']?.toString() ?? ''];
        data['live_trail_style'] = stylesByUser[data['id']?.toString() ?? ''];
        if (live != null) {
          data['live_latitude'] = live['latitude'];
          data['live_longitude'] = live['longitude'];
          data['live_updated_at'] = live['updated_at'];
          data['live_speed_kmh'] = live['speed_kmh'];
          data['live_activity'] = live['activity'];
          data['live_paused'] = live['paused'];
        }
        return FriendProfile.fromRow(data);
      }).toList();
    } on PostgrestException catch (error) {
      debugPrint(
        '[FriendService] fetchFriends ${error.code}: ${error.message}',
      );
      return userId == id ? await loadCachedFriends() ?? const [] : const [];
    } catch (error) {
      debugPrint('[FriendService] fetchFriends failed: $error');
      return userId == id ? await loadCachedFriends() ?? const [] : const [];
    }
  }

  /// Публичный профиль пользователя по id (для экрана профиля из поиска).
  Future<FriendProfile?> fetchPublicProfile(String userId) async {
    final client = _client;
    if (client == null) return null;

    try {
      final row = await client
          .from('public_profiles')
          .select(
            'id, username, avatar_url, status, city, '
            'preferred_riding_type, weight, age, gender',
          )
          .eq('id', userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 12));
      if (row == null) return null;
      return FriendProfile.fromRow(Map<String, dynamic>.from(row));
    } on PostgrestException catch (error) {
      debugPrint(
        '[FriendService] publicProfile ${error.code}: ${error.message}',
      );
      return null;
    } catch (error) {
      debugPrint('[FriendService] publicProfile failed: $error');
      return null;
    }
  }

  // ── Заявки ────────────────────────────────────────────────────────────

  /// Входящие заявки (ко мне).
  Future<List<FriendRequest>> fetchIncomingRequests({bool strict = false}) =>
      _fetchRequests(incoming: true, strict: strict);

  /// Исходящие заявки (от меня, ещё не принятые).
  Future<List<FriendRequest>> fetchOutgoingRequests() =>
      _fetchRequests(incoming: false);

  Future<List<FriendRequest>> _fetchRequests({
    required bool incoming,
    bool strict = false,
  }) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return const [];

    final meField = incoming ? 'to_user' : 'from_user';
    try {
      // 1) заявки; 2) имена/аватары контрагентов пакетом по id.
      final rows = await client
          .from('friend_requests')
          .select('id, from_user, to_user, created_at')
          .eq(meField, id)
          .order('created_at', ascending: false)
          .timeout(const Duration(seconds: 12));
      if (rows.isEmpty) return const [];

      final counterpartField = incoming ? 'from_user' : 'to_user';
      final userIds = rows
          .map(
            (raw) =>
                (Map<String, dynamic>.from(raw))[counterpartField]?.toString(),
          )
          .whereType<String>()
          .toSet()
          .toList();

      final profiles = await client
          .from('public_profiles')
          .select('id, username, avatar_url')
          .inFilter('id', userIds)
          .timeout(const Duration(seconds: 12));
      final profileById = <String, Map<String, dynamic>>{
        for (final raw in profiles) ((raw)['id'] ?? '').toString(): raw,
      };

      return rows.map((raw) {
        final row = Map<String, dynamic>.from(raw);
        final from = profileById[row['from_user']?.toString() ?? ''] ?? {};
        final to = profileById[row['to_user']?.toString() ?? ''] ?? {};
        return FriendRequest.fromRow({
          'id': row['id'],
          'from_user': row['from_user'],
          'to_user': row['to_user'],
          'created_at': row['created_at'],
          'from_username': from['username'],
          'from_avatar_url': from['avatar_url'],
          'to_username': to['username'],
          'to_avatar_url': to['avatar_url'],
        });
      }).toList();
    } on PostgrestException catch (error) {
      debugPrint('[FriendService] requests ${error.code}: ${error.message}');
      if (strict) rethrow;
      return const [];
    } catch (error) {
      debugPrint('[FriendService] requests failed: $error');
      if (strict) rethrow;
      return const [];
    }
  }

  /// Отправить заявку пользователю [targetUserId].
  Future<void> sendRequest(String targetUserId) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) {
      throw const FriendServiceException('Нет сессии. Войдите в аккаунт.');
    }
    if (targetUserId == id) {
      throw const FriendServiceException('Нельзя добавить себя в друзья.');
    }

    try {
      await client
          .from('friend_requests')
          .insert({'from_user': id, 'to_user': targetUserId})
          .timeout(const Duration(seconds: 15));
    } on PostgrestException catch (error) {
      if (error.code == '23505') {
        return; // already sent, no permission to update receiver-owned requests
      }
      debugPrint('[FriendService] send ${error.code}: ${error.message}');
      throw const FriendServiceException(
        'Не удалось отправить заявку. Возможно, вы уже друзья.',
      );
    } catch (error) {
      debugPrint('[FriendService] send failed: $error');
      throw const FriendServiceException(
        'Не удалось отправить заявку. Проверьте интернет.',
      );
    }
  }

  /// Принять заявку: создаёт обе симметричные строки дружбы, удаляет заявку.
  Future<void> acceptRequest(FriendRequest request) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) {
      throw const FriendServiceException('Нет сессии. Войдите в аккаунт.');
    }

    try {
      await client
          .rpc(
            'pulsepath_accept_friend_request',
            params: {'p_request_id': request.id},
          )
          .timeout(const Duration(seconds: 15));
    } on PostgrestException catch (error) {
      debugPrint('[FriendService] accept ${error.code}: ${error.message}');
      throw const FriendServiceException('Не удалось принять заявку.');
    } catch (error) {
      debugPrint('[FriendService] accept failed: $error');
      throw const FriendServiceException('Не удалось принять заявку.');
    }
  }

  /// Отклонить (или отозвать) заявку.
  Future<void> declineRequest(FriendRequest request) async {
    final client = _client;
    if (client == null) return;
    try {
      await client
          .from('friend_requests')
          .delete()
          .eq('id', request.id)
          .timeout(const Duration(seconds: 12));
    } on PostgrestException catch (error) {
      debugPrint('[FriendService] decline ${error.code}: ${error.message}');
    } catch (error) {
      debugPrint('[FriendService] decline failed: $error');
    }
  }

  /// Список друзей ДРУГОГО пользователя (вкладка «Друзья» в его профиле).
  /// Видимость списка регулируется его настройкой `show_friends`
  /// (проверяется на стороне вызывающего кода).
  Future<List<FriendProfile>> fetchFriendsOf(String userId) async {
    final client = _client;
    if (client == null) return const [];

    try {
      final rows = await client
          .from('friends')
          .select('friend_id')
          .eq('user_id', userId)
          .timeout(const Duration(seconds: 12));
      final friendIds = rows
          .map(
            (raw) => (Map<String, dynamic>.from(raw))['friend_id']?.toString(),
          )
          .whereType<String>()
          .toList();
      if (friendIds.isEmpty) return const [];

      final profiles = await client
          .from('public_profiles')
          .select('id, username, avatar_url, status, city')
          .inFilter('id', friendIds)
          .timeout(const Duration(seconds: 12));

      return profiles
          .map((raw) => FriendProfile.fromRow(Map<String, dynamic>.from(raw)))
          .toList();
    } on PostgrestException catch (error) {
      debugPrint('[FriendService] friendsOf ${error.code}: ${error.message}');
      return const [];
    } catch (error) {
      debugPrint('[FriendService] friendsOf failed: $error');
      return const [];
    }
  }

  /// Поиск райдеров по имени (публичная проекция `public_profiles`).
  Future<List<FriendProfile>> searchUsers(String query) async {
    final client = _client;
    if (client == null) return const [];
    final cleaned = query.trim();
    if (cleaned.length < 2) return const [];

    try {
      // Экранируем wildcards, чтобы «%»/«_» в запросе не превращались в
      // скан-шаблоны (как в ChatService.fetchConversation).
      final escaped = cleaned
          .replaceAll(r'\', r'\\')
          .replaceAll('%', r'\%')
          .replaceAll('_', r'\_');
      final rows = await client
          .from('public_profiles')
          .select(
            'id, username, avatar_url, status, city, '
            'preferred_riding_type, weight, age, gender',
          )
          .ilike('username', '%$escaped%')
          .limit(15)
          .timeout(const Duration(seconds: 12));

      return rows
          .map((raw) => FriendProfile.fromRow(Map<String, dynamic>.from(raw)))
          .toList();
    } on PostgrestException catch (error) {
      debugPrint('[FriendService] search ${error.code}: ${error.message}');
      return const [];
    } catch (error) {
      debugPrint('[FriendService] search failed: $error');
      return const [];
    }
  }

  // ── Живые позиции ─────────────────────────────────────────────────────

  /// Публикует свою позицию во время заезда (вызывается по троттлингу).
  Future<void> updateLivePosition(
    LatLng position, {
    double? speedKmh,
    String? activity,
    bool paused = false,
  }) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return;
    try {
      await client
          .from('live_positions')
          .upsert({
            'speed_kmh': speedKmh != null && speedKmh.isFinite
                ? speedKmh.clamp(0, 300)
                : null,
            'activity': activity,
            'paused': paused,
            'user_id': id,
            'latitude': position.latitude,
            'longitude': position.longitude,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }, onConflict: 'user_id')
          .timeout(const Duration(seconds: 10));
    } on PostgrestException catch (error) {
      debugPrint('[FriendService] live upsert ${error.code}: ${error.message}');
    } catch (error) {
      debugPrint('[FriendService] live failed: $error');
    }
  }

  /// Убирает свою позицию из трансляции (после финиша).
  Future<void> clearLivePosition() async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return;
    try {
      await client
          .from('live_positions')
          .delete()
          .eq('user_id', id)
          .timeout(const Duration(seconds: 12));
    } catch (_) {}
  }

  /// Подписка на изменения живых позиций (Realtime). [onChanged] вызывается
  /// с (userId, lat, lon) по каждому изменению — фильтрация по друзьям на
  /// стороне вызывающего кода.
  Future<void> subscribePositions(
    void Function(
      String userId,
      double lat,
      double lon,
      DateTime updatedAt,
      double? speedKmh,
      String? activity,
      bool paused,
    )
    onChanged, {
    void Function(String userId, LiveTrailStyle style)? onStyleChanged,
  }) async {
    final client = _client;
    if (client == null) return;

    await unsubscribePositions();
    try {
      _positionsChannel = client
          .channel('live_positions_feed')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'profile_trail_styles',
            callback: (payload) {
              final row = payload.newRecord;
              final owner = row['user_id'];
              if (owner is String && owner.isNotEmpty) {
                onStyleChanged?.call(owner, LiveTrailStyle.fromRow(row));
              }
            },
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'live_positions',
            callback: (payload) {
              final newRecord = payload.newRecord;
              final userId = (newRecord['user_id'] ?? '').toString();
              final lat = (newRecord['latitude'] as num?)?.toDouble();
              final lon = (newRecord['longitude'] as num?)?.toDouble();
              // DELETE-событие приходит с пустым newRecord — позицию друга
              // убирает вызывающий код по таймауту hasLivePosition.
              if (userId.isNotEmpty && lat != null && lon != null) {
                onChanged(
                  userId,
                  lat,
                  lon,
                  DateTime.tryParse(
                        newRecord['updated_at']?.toString() ?? '',
                      ) ??
                      DateTime.fromMillisecondsSinceEpoch(0),
                  (newRecord['speed_kmh'] as num?)?.toDouble(),
                  newRecord['activity'] as String?,
                  newRecord['paused'] == true,
                );
              }
            },
          )
          .subscribe();
    } catch (error) {
      debugPrint('[FriendService] realtime subscribe failed: $error');
    }
  }

  /// Исправлено: теперь при удалении друга его Live-позиция также удаляется
  Future<bool> removeFriend(String friendId) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return false;

    try {
      // Удаляем симметричные строки дружбы через RPC
      await client
          .rpc('pulsepath_remove_friend', params: {'p_friend_id': friendId})
          .timeout(const Duration(seconds: 15));

      // Исправлено: удаляем Live-позицию друга из таблицы live_positions
      await client
          .from('live_positions')
          .delete()
          .eq('user_id', friendId)
          .timeout(const Duration(seconds: 12));

      return true;
    } on PostgrestException catch (error) {
      debugPrint('[FriendService] remove ${error.code}: ${error.message}');
      return false;
    } catch (error) {
      debugPrint('[FriendService] remove failed: $error');
      return false;
    }
  }

  Future<void> unsubscribePositions() async {
    final channel = _positionsChannel;
    _positionsChannel = null;
    try {
      await channel?.unsubscribe();
    } catch (_) {}
  }
}
