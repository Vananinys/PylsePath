import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, AppLifecycleState;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/shared_route.dart';
import '../models/group_coordination.dart';
import '../utils/ride_id.dart';
import '../config/app_variant.dart';
import 'group_workout_navigation.dart';

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
  GroupRideService._()
    : _testClient = null,
      _realtimeEnabled = true,
      uiFlow = AppVariant.uiBeta;
  @visibleForTesting
  GroupRideService.forTesting({SupabaseClient? client, this.uiFlow = false})
    : _testClient = client,
      _realtimeEnabled = false;
  final SupabaseClient? _testClient;
  final bool _realtimeEnabled;
  final bool uiFlow;
  List<Map<String, dynamic>> invitations = [];
  List<GroupMember> lastParticipants = [];
  String? _finishedRoom, _finishLoadedFor;
  String? _newRideIntent, _newRideRoom;
  bool get ownFinished =>
      activeRoomId != null &&
      (_finishedRoom == activeRoomId ||
          members.any(
            (m) => m.userId == userId && m.workoutState == 'finished',
          ));
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
  final Map<String, String> _awaitedInvitees = {};
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
    _awaitedInvitees.clear();
    invitations = [];
    lastParticipants = [];
    _newRideIntent = null;
    _newRideRoom = null;
    refreshing = false;
    _finishedRoom = null;
    _finishLoadedFor = null;
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
      if (uiFlow && _finishLoadedFor != owner) {
        final prefs = await SharedPreferences.getInstance();
        if (owner != userId || generation != _generation) return;
        _finishedRoom = prefs.getString('group_finished_room_$owner');
        _finishLoadedFor = owner;
      }
      final raw = await _client!
          .rpc(uiFlow ? 'group_ui_snapshot' : 'group_room_snapshot_v2')
          .timeout(const Duration(seconds: 15));
      if (owner != userId || generation != _generation) return;
      await _applyUi(raw);
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
    final accepted =
        isHost &&
        members.any((m) => _awaitedInvitees[m.userId] == activeRoomId);
    _awaitedInvitees.removeWhere(
      (id, room) => room != activeRoomId || members.any((m) => m.userId == id),
    );
    if (AppVariant.uiBeta &&
        accepted &&
        activeRoomId != null &&
        userId != null) {
      GroupWorkoutNavigation.instance.prepare(
        room: activeRoomId!,
        owner: userId!,
      );
    }
  }

  Future<void> _applyUi(dynamic raw) async {
    if (uiFlow && raw is Map && raw.containsKey('room')) {
      invitations = (raw['invitations'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      await _apply(raw['room']);
    } else {
      await _apply(raw);
    }
  }

  Future<void> newRide({
    String title = 'Совместная тренировка',
    bool replace = false,
  }) async {
    if (!uiFlow) {
      await createRoom(title: title, replace: replace);
      return;
    }
    bindToUser(userId);
    if (_newRideIntent == null) {
      _newRideIntent = newRideId();
      _newRideRoom = activeRoomId;
    }
    dynamic raw;
    try {
      raw = await _call('group_ui_action', {
        'p_action': 'fresh',
        'p_data': {
          'title': title,
          'replace': replace,
          'room_id': _newRideRoom,
          'request_id': _newRideIntent,
        },
      });
    } on GroupRideException catch (error) {
      if (error.intentRejected) {
        _newRideIntent = null;
        _newRideRoom = null;
      }
      rethrow;
    }
    _generation++;
    _refreshFuture = null;
    refreshing = false;
    await _applyUi(raw);
    _newRideIntent = null;
    _newRideRoom = null;
    error = null;
    notice = 'Новый заезд создан. Пригласите участников.';
    lastSyncedAt = DateTime.now();
    notifyListeners();
  }

  Future<void> endParticipation() async {
    if (activeRoomId == null) return;
    if (!uiFlow) {
      await leaveRoom(activeRoomId!, isHost: isHost);
      return;
    }
    final raw = await _call('group_ui_action', {
      'p_action': 'depart',
      'p_data': {'room_id': activeRoomId},
    });
    if (raw is Map && raw['previous'] is Map) {
      lastParticipants = ((raw['previous'] as Map)['members'] as List? ?? [])
          .whereType<Map>()
          .map((e) => GroupMember.fromRow(Map<String, dynamic>.from(e)))
          .toList();
    }
    _generation++;
    _refreshFuture = null;
    refreshing = false;
    await _applyUi(raw);
    error = null;
    notice = 'Вы завершили участие. Следующий заезд начинается с нового приглашения.';
    lastSyncedAt = DateTime.now();
    notifyListeners();
  }

  Future<void> finishPersonalWorkout(
    String room,
    double distance,
    int seconds,
  ) async {
    final owner = userId;
    if (owner == null || room != activeRoomId) return;
    _finishedRoom = room;
    members = members
        .map(
          (m) => m.userId != owner
              ? m
              : GroupMember(
                  userId: m.userId,
                  username: m.username,
                  avatarUrl: m.avatarUrl,
                  distanceMeters: distance,
                  durationSeconds: seconds,
                  updatedAt: DateTime.now(),
                  workoutState: 'finished',
                ),
        )
        .toList();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (owner == userId)
        await prefs.setString('group_finished_room_$owner', room);
    } catch (_) {}
    if (owner != userId || room != activeRoomId) return;
    error = null;
    await updateProgress(
      room,
      distanceMeters: distance,
      durationSeconds: seconds,
      workoutState: 'finished',
    );
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
      if (text.contains('ALREADY_JOINED'))
        throw const GroupRideException(
          'Этот человек уже участвует. Для следующего заезда создайте новый.',
        );
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
    if (uiFlow) {
      await newRide(title: title, replace: replace);
      return activeCode!;
    }
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
  ) async {
    final room = activeRoomId;
    if (members.any((m) => m.userId == receiver)) {
      throw const GroupRideException(
        'Этот человек уже участвует в прежней поездке. Для нового приглашения создайте новую поездку.',
      );
    }
    final result = Map<String, dynamic>.from(
      await _call(
        uiFlow ? 'group_ui_action' : 'group_invite_send',
        uiFlow
            ? {
                'p_action': 'invite',
                'p_data': {'receiver_id': receiver, 'id': messageId},
              }
            : {'p_receiver': receiver, 'p_id': messageId},
      ) as Map,
    );
    if (AppVariant.uiBeta &&
        room != null &&
        room == activeRoomId &&
        !members.any((m) => m.userId == receiver)) {
      _awaitedInvitees[receiver] = room;
    }
    if (uiFlow) await refreshMembers();
    return result;
  }

  Future<Map<String, dynamic>> invitation(
    String id, {
    String action = 'view',
    bool replace = false,
  }) async {
    final result = Map<String, dynamic>.from(
      await _call(
        uiFlow ? 'group_ui_action' : 'group_invite_action',
        uiFlow
            ? {
                'p_action': action,
                'p_data': {'id': id, 'replace': replace},
              }
            : {'p_id': id, 'p_action': action, 'p_replace': replace},
      ) as Map,
    );
    if (action == 'accept' ||
        uiFlow && (action == 'decline' || action == 'revoke')) {
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
