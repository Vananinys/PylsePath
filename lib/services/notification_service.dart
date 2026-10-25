import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/user_scope.dart';
import '../models/chat_message.dart';
import 'chat_service.dart';
import 'friend_service.dart';

enum AppNotificationType { chat, friendRequest, system }

class AppNotification {
  final String id;
  final AppNotificationType type;
  final String title;
  final String subtitle;
  final DateTime createdAt;
  final String? payloadUserId;
  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.createdAt,
    this.payloadUserId,
  });
}

/// Badge counts visible conversations plus requests, not individual messages.
class NotificationService extends ChangeNotifier {
  NotificationService._();
  static final instance = NotificationService._();
  static final badge = ValueNotifier<int>(0);
  final _friendService = FriendService();
  final _chatService = ChatService();
  final List<AppNotification> _items = [];
  final Map<String, String> _usernames = {};
  final Map<String, String> _fingerprints = {};
  final Map<String, String> _dismissed = {};
  final Set<String> _handled = {};
  String? _owner;
  int _epoch = 0, _revision = 0, _request = 0;
  RealtimeChannel? _requestsChannel;
  List<AppNotification> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  void bindToUser(String? uid) {
    if (_owner == uid) return;
    _epoch++;
    _revision++;
    _request++;
    final old = _requestsChannel;
    _requestsChannel = null;
    if (old != null) unawaited(old.unsubscribe());
    _owner = uid;
    _items.clear();
    _usernames.clear();
    _fingerprints.clear();
    _dismissed.clear();
    _handled.clear();
    _publish();
    if (uid == null) return;
    try {
      _requestsChannel = Supabase.instance.client
          .channel('notifications_requests_$uid')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'friend_requests',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'to_user',
              value: uid,
            ),
            callback: (_) {
              unawaited(refresh());
            },
          )
          .subscribe();
    } catch (error) {
      debugPrint('[Notifications] subscribe failed: $error');
    }
  }

  void _publish() {
    _items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    badge.value = _items
        .where((n) => n.type != AppNotificationType.system)
        .length;
    notifyListeners();
  }

  bool _visible(String id, String fingerprint) => _dismissed[id] != fingerprint;
  Future<void> refresh() async {
    final uid = UserScope.currentUserId();
    bindToUser(uid);
    if (uid == null) return;
    final epoch = _epoch, revision = _revision, request = ++_request;
    try {
      final requests = await _friendService.fetchIncomingRequests(strict: true);
      final unread = await _chatService.unreadByFriend(strict: true);
      final recent = await _chatService.fetchRecent(limit: 300, strict: true);
      if (epoch != _epoch ||
          request != _request ||
          revision != _revision ||
          UserScope.currentUserId() != uid) {
        return;
      }
      final built = <AppNotification>[];
      final fingerprints = <String, String>{};
      for (final r in requests) {
        final id = 'request_${r.id}', fingerprint = r.id;
        fingerprints[id] = fingerprint;
        if (!_visible(id, fingerprint)) continue;
        built.add(
          AppNotification(
            id: id,
            type: AppNotificationType.friendRequest,
            title: 'Заявка в друзья',
            subtitle: '${r.fromUsername} хочет добавить вас',
            createdAt: r.createdAt,
            payloadUserId: r.fromUserId,
          ),
        );
      }
      for (final entry in unread.entries) {
        if (entry.key == ChatService.openChatFriendId) continue;
        ChatMessage? last;
        for (final m in recent) {
          if (m.senderId == entry.key && m.receiverId == uid && !m.isRead) {
            last = m;
            break;
          }
        }
        final id = 'chat_${entry.key}';
        final fingerprint = last?.id ?? 'count_${entry.value}';
        fingerprints[id] = fingerprint;
        if (!_visible(id, fingerprint)) continue;
        built.add(
          AppNotification(
            id: id,
            type: AppNotificationType.chat,
            title: 'Новое сообщение',
            subtitle: last == null
                ? 'Новые сообщения: ${entry.value}'
                : _preview(last),
            createdAt:
                last?.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
            payloadUserId: entry.key,
          ),
        );
      }
      final system = _items
          .where((n) => n.type == AppNotificationType.system)
          .toList();
      _items
        ..clear()
        ..addAll(built)
        ..addAll(system);
      _fingerprints
        ..clear()
        ..addAll(fingerprints);
      _publish();
    } catch (error) {
      // A network failure is not an empty inbox. Keep the previous snapshot.
      debugPrint('[Notifications] refresh failed: $error');
    }
  }

  String _preview(ChatMessage m) => m.isStickerOnly
      ? 'Стикер ${m.sticker}'
      : m.isPhoto
      ? '📷 Фото'
      : m.isVoice
      ? '🎤 Голосовое сообщение'
      : m.body ?? '';
  Future<AppNotification?> notifyIncomingMessage(ChatMessage message) async {
    final uid = UserScope.currentUserId();
    bindToUser(uid);
    if (uid == null ||
        message.receiverId != uid ||
        message.isRead ||
        ChatService.openChatFriendId == message.senderId ||
        !_handled.add(message.id)) {
      return null;
    }
    if (_handled.length > 2000) _handled.remove(_handled.first);
    final epoch = _epoch;
    _revision++;
    var username = _usernames[message.senderId];
    if (username == null) {
      try {
        username = (await _friendService.fetchPublicProfile(message.senderId))
            ?.username;
      } catch (_) {
        /* fallback below */
      }
      username = (username?.isNotEmpty ?? false) ? username : 'Райдер';
    }
    if (epoch != _epoch ||
        UserScope.currentUserId() != uid ||
        ChatService.openChatFriendId == message.senderId) {
      return null;
    }
    _usernames[message.senderId] = username!;
    final id = 'chat_${message.senderId}';
    final existing = _items.where((n) => n.id == id).toList();
    if (existing.isNotEmpty &&
        existing.first.createdAt.isAfter(message.createdAt)) {
      return null;
    }
    _revision++;
    _dismissed.remove(id);
    _fingerprints[id] = message.id;
    final notification = AppNotification(
      id: id,
      type: AppNotificationType.chat,
      title: 'Новое сообщение от $username',
      subtitle: _preview(message),
      createdAt: message.createdAt,
      payloadUserId: message.senderId,
    );
    _items.removeWhere((n) => n.id == id);
    _items.add(notification);
    _publish();
    return notification;
  }

  void setMaintenance(String? body) {
    _items.removeWhere((n) => n.id == 'garage_maintenance');
    if (body != null) {
      _items.add(
        AppNotification(
          id: 'garage_maintenance',
          type: AppNotificationType.system,
          title: 'Пора проверить велосипед',
          subtitle: body,
          createdAt: DateTime.now(),
        ),
      );
    }
    _publish();
  }

  void pushSystem(String title, {String? subtitle}) {
    bindToUser(UserScope.currentUserId());
    _revision++;
    _items.add(
      AppNotification(
        id: 'system_${DateTime.now().microsecondsSinceEpoch}',
        type: AppNotificationType.system,
        title: title,
        subtitle: subtitle ?? '',
        createdAt: DateTime.now(),
      ),
    );
    final system =
        _items.where((n) => n.type == AppNotificationType.system).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final old in system.skip(50)) {
      _items.remove(old);
    }
    _publish();
  }

  void remove(String id) {
    _revision++;
    final fingerprint = _fingerprints[id];
    if (fingerprint != null) _dismissed[id] = fingerprint;
    _items.removeWhere((n) => n.id == id);
    _publish();
  }

  /// Hide current items for this session; this does not mark messages read.
  void clearAll() {
    _revision++;
    _dismissed.addAll(_fingerprints);
    _items.clear();
    _publish();
  }
}
