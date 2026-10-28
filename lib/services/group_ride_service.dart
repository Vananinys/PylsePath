import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, AppLifecycleState;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/shared_route.dart';
import '../models/group_coordination.dart';
import '../utils/ride_id.dart';

class GroupRideException implements Exception {
  const GroupRideException(
    this.message, {
    this.replaceRequired = false,
    this.intentRejected = false,
  });
  final String message;
  final bool replaceRequired;
  final bool intentRejected;
  @override
  String toString() => message;
}

class GroupMember {
  const GroupMember({
    required this.userId,
    required this.username,
    this.avatarUrl,
    required this.distanceMeters,
    required this.durationSeconds,
    this.latitude,
    this.longitude,
    required this.updatedAt,
    this.workoutState = 'waiting',
  });
  final String userId, username, workoutState;
  final String? avatarUrl;
  final double distanceMeters;
  final int durationSeconds;
  final double? latitude, longitude;
  final DateTime updatedAt;
  bool get isLive => DateTime.now().difference(updatedAt).inSeconds < 120;
  String get ageText {
    final seconds = DateTime.now().difference(updatedAt).inSeconds;
    if (seconds < 15) return 'только что';
    if (seconds < 60) return '$seconds с назад';
    if (seconds < 3600) return '${seconds ~/ 60} мин назад';
    return '${seconds ~/ 3600} ч назад';
  }

  factory GroupMember.fromRow(Map<String, dynamic> row) {
    final p = row['profile'] as Map? ?? {};
    return GroupMember(
      userId: row['user_id'].toString(),
      username: (p['username']?.toString().trim().isNotEmpty ?? false)
          ? p['username'].toString()
          : 'Райдер',
      avatarUrl: p['avatar_url'] as String?,
      distanceMeters: (row['distance_m'] as num?)?.toDouble() ?? 0,
      durationSeconds: (row['duration_seconds'] as num?)?.toInt() ?? 0,
      latitude: (row['latitude'] as num?)?.toDouble(),
      longitude: (row['longitude'] as num?)?.toDouble(),
      updatedAt:
          DateTime.tryParse(row['updated_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      workoutState: row['workout_state']?.toString() ?? 'waiting',
    );
  }
}

/// Failed reads retain the last snapshot. Mutations are atomic on the server.
class GroupRideService extends ChangeNotifier {
  factory GroupRideService() => _instance;
  GroupRideService._() : _testClient = null, _realtimeEnabled = true;
  @visibleForTesting
  GroupRideService.forTesting({SupabaseClient? client})
    : _testClient = client,
      _realtimeEnabled = false;
  final SupabaseClient? _testClient;
  final bool _realtimeEnabled;
  static final _instance = GroupRideService._();
  SupabaseClient? get _client {
    if (_testClient != null) return _testClient;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  String? get userId => _client?.auth.currentUser?.id;
  String? _owner;
  int _generation = 0;
  int membershipRevision = 0;
  String? activeRoomId, activeCode;
  String title = 'Совместная тренировка';
  bool isHost = false, refreshing = false, realtimeConnected = false;
  List<GroupMember> members = [];
  SharedRoute? route;
  String? hostId;
  GroupCoordination coordination = const GroupCoordination();
  Duration _serverOffset = Duration.zero;
  Timer? _coordinationPoll;
  Object? _coordinationToken;
  bool get coordinating => _coordinationToken != null;
  final Map<String, GroupPendingIntent> _pendingIntents = {};
  String? error, notice;
  DateTime? lastSyncedAt;
  RealtimeChannel? _channel;
  Timer? _debounce;
  Future<void>? _refreshFuture;
  void bindToUser(String? owner) {
    if (_owner == owner) return;
    _owner = owner;
    clearSession();
  }

  void clearSession() {
    membershipRevision++;
    _generation++;
    activeRoomId = null;
    activeCode = null;
    members = [];
    isHost = false;
    route = null;
    hostId = null;
    coordination = const GroupCoordination();
    _coordinationPoll?.cancel();
    _coordinationPoll = null;
    _coordinationToken = null;
    _pendingIntents.clear();
    error = null;
    notice = null;
    refreshing = false;
    lastSyncedAt = null;
    _refreshFuture = null;
    _debounce?.cancel();
    unawaited(unsubscribe());
    notifyListeners();
  }

  Future<void> restoreSession() => refreshMembers();
  Future<void> refreshMembers() {
    bindToUser(userId);
    if (coordinating) return Future.value();
    return _refreshFuture ??= _refresh();
  }

  Future<void> _refresh() async {
    final owner = userId, generation = _generation;
    if (owner == null || _client == null) return;
    refreshing = true;
    notifyListeners();
    try {
      final raw = await _client!
          .rpc('group_room_snapshot_v2')
          .timeout(const Duration(seconds: 15));
      if (owner != userId || generation != _generation) return;
      await _apply(raw);
      error = null;
      lastSyncedAt = DateTime.now();
    } catch (_) {
      if (owner == userId && generation == _generation) {
        error = 'Не удалось обновить комнату. Последние данные сохранены.';
      }
    } finally {
      if (owner == userId && generation == _generation) {
        refreshing = false;
        _refreshFuture = null;
        notifyListeners();
      }
    }
  }

  Future<void> _apply(dynamic raw) async {
    final old = activeRoomId;
    final nextRoom = raw is Map ? raw['id']?.toString() : null;
    if (old != nextRoom) membershipRevision++;
    if (raw == null) {
      activeRoomId = null;
      activeCode = null;
      members = [];
      route = null;
      hostId = null;
      coordination = const GroupCoordination();
      _coordinationPoll?.cancel();
      _coordinationPoll = null;
      isHost = false;
      if (old != null) notice = 'Комната закрыта или вы вышли на другом устройстве. Личная тренировка продолжается.';
      await unsubscribe();
    } else {
      final row = Map<String, dynamic>.from(raw as Map);
      activeRoomId = row['id'].toString();
      activeCode = row['code'].toString();
      title = row['title']?.toString() ?? 'Совместная тренировка';
      isHost = row['host_id'] == userId;
      hostId = row['host_id']?.toString();
      route = SharedRoute.tryParse(row['route_attachment']);
      final serverNow = DateTime.tryParse(row['server_now']?.toString() ?? '');
      final clockOffset = serverNow == null
          ? Duration.zero
          : DateTime.now().difference(serverNow);
      _serverOffset = clockOffset;
      if (row.containsKey('coordination')) {
        coordination = GroupCoordination.fromRow(
          row['coordination'],
          clockOffset: clockOffset,
        );
      } else if (old != activeRoomId) {
        coordination = const GroupCoordination();
      }
      members = (row['members'] as List? ?? []).whereType<Map>().map((m) {
        final member = Map<String, dynamic>.from(m);
        final at = DateTime.tryParse(member['updated_at']?.toString() ?? '');
        if (at != null) {
          member['updated_at'] = at.add(clockOffset).toIso8601String();
        }
        return GroupMember.fromRow(member);
      }).toList();
      notice = null;
      if (old != activeRoomId || _channel == null) {
        await subscribe(activeRoomId!, _scheduleRefresh);
      }
      if (_realtimeEnabled) {
        _coordinationPoll ??= Timer.periodic(const Duration(seconds: 5), (_) {
          if (activeRoomId != null &&
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed) {
            unawaited(refreshMembers());
          }
        });
      }
    }
    notifyListeners();
  }

  void _scheduleRefresh() {
    if (_debounce?.isActive ?? false) return;
    final elapsed = lastSyncedAt == null
        ? 5000
        : DateTime.now().difference(lastSyncedAt!).inMilliseconds;
    _debounce = Timer(
      Duration(milliseconds: (5000 - elapsed).clamp(350, 5000)),
      () => unawaited(refreshMembers()),
    );
  }

  Future<dynamic> _call(String method, Map<String, dynamic> params) async {
    bindToUser(userId);
    final owner = userId, generation = _generation;
    if (owner == null) throw const GroupRideException('Войдите в аккаунт.');
    try {
      final result = await _client!
          .rpc(method, params: params)
          .timeout(const Duration(seconds: 20));
      if (owner != userId || generation != _generation) {
        throw const GroupRideException('Аккаунт или комната изменились.');
      }
      return result;
    } on GroupRideException {
      rethrow;
    } catch (cause) {
      final text = cause is PostgrestException ? cause.message : '';
      if (text.contains('SIGNAL_EXPIRED')) {
        throw const GroupRideException(
          'Срок команды истёк. Обновите комнату и отправьте новую.',
          intentRejected: true,
        );
      }
      if (text.contains('COORDINATION_RATE_LIMIT')) {
        throw const GroupRideException(
          'Подождите три секунды перед следующей командой.',
          intentRejected: true,
        );
      }
      if (text.contains('MEMBER_UNAVAILABLE') ||
          text.contains('ROOM_CHANGED') ||
          text.contains('REQUEST_CONFLICT')) {
        throw const GroupRideException(
          'Состав или управление комнаты изменились. Обновите её.',
          intentRejected: true,
        );
      }
      if (text.contains('INVALID_COORDINATION')) {
        throw const GroupRideException(
          'Проверьте место, время и параметры команды.',
          intentRejected: true,
        );
      }
      if (text.contains('REPLACE_REQUIRED')) {
        throw const GroupRideException(
          'Вы уже в другой комнате. При переходе ваша комната организатора закроется для всех.',
          replaceRequired: true,
        );
      }
      if (text.contains('ROOM_CLOSED')) {
        throw const GroupRideException('Комната не найдена или уже закрыта.');
      }
      if (text.contains('FRIEND_REQUIRED')) {
        throw const GroupRideException(
          'Приглашения доступны друзьям без блокировки переписки.',
        );
      }
      if (text.contains('HOST_REQUIRED')) {
        throw const GroupRideException(
          'Это действие доступно организатору текущего заезда.',
          intentRejected: true,
        );
      }
      if (text.contains('INVITATION_UNAVAILABLE')) {
        throw const GroupRideException(
          'Приглашение больше недоступно. Обновите его состояние.',
        );
      }
      if (text.contains('RATE_LIMIT')) {
        throw const GroupRideException(
          'Слишком много приглашений. Повторите через минуту.',
        );
      }
      throw const GroupRideException(
        'Сервер не подтвердил действие. Проверьте связь и повторите.',
      );
    }
  }

  Future<void> _action(Map<String, dynamic> params) async {
    bindToUser(userId);
    _generation++;
    _refreshFuture = null;
    refreshing = false;
    final result = await _call('group_room_action', params);
    // Discard reads that started while the server mutation was in flight.
    _generation++;
    _refreshFuture = null;
    refreshing = false;
    await _apply(result);
    error = null;
    lastSyncedAt = DateTime.now();
    notifyListeners();
  }

  Future<String> createRoom({
    String title = 'Совместная тренировка',
    bool replace = false,
  }) async {
    await _action({
      'p_action': 'create',
      'p_title': title,
      'p_replace': replace,
    });
    return activeCode!;
  }

  Future<String> joinRoom(String code, {bool replace = false}) async {
    final clean = code.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9]{12}$').hasMatch(clean)) {
      throw const GroupRideException('Введите 12 символов кода комнаты.');
    }
    await _action({'p_action': 'join', 'p_code': clean, 'p_replace': replace});
    return activeRoomId!;
  }

  Future<void> leaveRoom(String roomId, {required bool isHost}) async {
    if (roomId != activeRoomId) {
      throw const GroupRideException('Комната изменилась. Обновите экран.');
    }
    await _action({'p_action': 'leave', 'p_code': activeCode});
    notice = 'Вы вышли из комнаты. Личная тренировка продолжается.';
    notifyListeners();
  }

  Future<void> setRoute(SharedRoute? route) =>
      _action({'p_action': 'route', 'p_route': route?.toJson()});

  Future<void> _coordinate(String action, Map<String, dynamic> payload) async {
    bindToUser(userId);
    if (coordinating) {
      throw const GroupRideException(
        'Дождитесь подтверждения предыдущего действия.',
      );
    }
    final room = activeRoomId, owner = userId;
    if (room == null || owner == null) {
      throw const GroupRideException('Откройте текущую комнату заново.');
    }
    final token = Object();
    _coordinationToken = token;
    _generation++;
    _refreshFuture = null;
    refreshing = false;
    final generation = _generation;
    final key = '$room|$action|${jsonEncode(payload)}';
    final now = DateTime.now();
    _pendingIntents.removeWhere((_, value) => !value.reusableAt(now));
    var intent = _pendingIntents[key];
    if (intent == null || !intent.reusableAt(now)) {
      intent = GroupPendingIntent(
        id: newRideId(),
        createdAt: now,
        payload: {
          ...payload,
          if (action == 'signal')
            'valid_until': now
                .toUtc()
                .subtract(_serverOffset)
                .add(const Duration(seconds: 30))
                .toIso8601String(),
        },
      );
      _pendingIntents[key] = intent;
    }
    notifyListeners();
    try {
      final result = await _call('group_coordination_action', {
        'p_room': room,
        'p_action': action,
        'p_request': intent.id,
        'p_payload': intent.payload,
      });
      if (owner != userId ||
          room != activeRoomId ||
          generation != _generation) {
        throw const GroupRideException('Аккаунт или комната изменились.');
      }
      _generation++;
      _refreshFuture = null;
      _pendingIntents.clear();
      await _apply(result);
      error = null;
      lastSyncedAt = DateTime.now();
    } on GroupRideException catch (cause) {
      if (cause.intentRejected) _pendingIntents.remove(key);
      rethrow;
    } finally {
      if (identical(_coordinationToken, token)) {
        _coordinationToken = null;
        notifyListeners();
      }
    }
  }

  Future<void> setReadiness(GroupReadiness state) =>
      _coordinate('readiness', {'state': state.name});
  Future<void> setMeeting(GroupMeetPlan plan) =>
      _coordinate('settings', plan.toPayload());
  Future<void> sendSignal(
    GroupSignalKind kind, {
    double? latitude,
    double? longitude,
    String note = '',
  }) => _coordinate('signal', {
    'kind': kind.name,
    'latitude': latitude,
    'longitude': longitude,
    if (note.isNotEmpty) 'note': note.trim(),
  });
  Future<void> respondToSignal(String id, String response) =>
      _coordinate('ack', {'signal_id': id, 'response': response});
  Future<void> clearSignal() => _coordinate('clear_signal', {});
  Future<void> transferHost(String target) =>
      _coordinate('transfer', {'target': target, 'expected_host': hostId});
  Future<Map<String, dynamic>> sendInvitation(
    String receiver,
    String messageId,
  ) async => Map<String, dynamic>.from(
    await _call('group_invite_send', {
      'p_receiver': receiver,
      'p_id': messageId,
    }) as Map,
  );
  Future<Map<String, dynamic>> invitation(
    String id, {
    String action = 'view',
    bool replace = false,
  }) async {
    final result = Map<String, dynamic>.from(
      await _call('group_invite_action', {
        'p_id': id,
        'p_action': action,
        'p_replace': replace,
      }) as Map,
    );
    if (action == 'accept') {
      _generation++;
      _refreshFuture = null;
      await refreshMembers();
    }
    return result;
  }

  Future<void> updateProgress(
    String roomId, {
    required double distanceMeters,
    required int durationSeconds,
    double? latitude,
    double? longitude,
    String workoutState = 'waiting',
  }) async {
    final owner = userId, generation = _generation;
    if (owner == null || activeRoomId != roomId) return;
    try {
      final rows = await _client!
          .from('group_rides_members')
          .update({
            'distance_m': distanceMeters,
            'duration_seconds': durationSeconds,
            'latitude': latitude,
            'longitude': longitude,
            'workout_state': workoutState,
          })
          .eq('group_id', roomId)
          .eq('user_id', owner)
          .select('id')
          .timeout(const Duration(seconds: 12));
      if (owner != userId || generation != _generation) return;
      if (rows.isEmpty) await refreshMembers();
    } catch (_) {
      if (owner == userId && generation == _generation) {
        error = 'Нет подтверждения отправки прогресса. Проверьте связь.';
        notifyListeners();
      }
    }
  }

  Future<void> subscribe(String roomId, void Function() onChanged) async {
    if (!_realtimeEnabled) return;
    await unsubscribe();
    final owner = userId;
    if (_client == null || activeRoomId != roomId) return;
    final channel = _client!.channel('group_ride_${owner}_$roomId');
    _channel = channel;
    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'group_rides_members',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'group_id',
            value: roomId,
          ),
          callback: (payload) {
            if (_channel == channel &&
                owner == userId &&
                payload.newRecord['user_id'] != owner) {
              onChanged();
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'group_rides',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: roomId,
          ),
          callback: (_) {
            if (_channel == channel && owner == userId) onChanged();
          },
        )
        .subscribe((status, cause) {
          if (_channel != channel || owner != userId) return;
          realtimeConnected = status == RealtimeSubscribeStatus.subscribed;
          notifyListeners();
          if (realtimeConnected) _scheduleRefresh();
        });
  }

  Future<void> unsubscribe() async {
    final channel = _channel;
    _channel = null;
    realtimeConnected = false;
    if (channel != null) {
      try {
        await _client?.removeChannel(channel);
      } catch (_) {}
    }
  }
}
