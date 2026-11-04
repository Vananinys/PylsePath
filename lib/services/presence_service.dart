import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class UserPresence {
  const UserPresence(this.online, this.lastSeen);
  final bool online;
  final DateTime? lastSeen;
  DateTime? nextChangeAt(DateTime now) {
    final seen = lastSeen;
    if (seen == null) return null;
    if (isOnlineAt(now)) return seen.add(const Duration(seconds: 70));
    final age = now.difference(seen);
    final labelChange = seen.add(
      age.inMinutes < 1
          ? const Duration(minutes: 1)
          : age.inMinutes < 60
          ? Duration(minutes: age.inMinutes + 1)
          : age.inHours < 24
          ? Duration(hours: age.inHours + 1)
          : Duration(days: age.inDays + 1),
    );
    // Preserve the existing tolerance for a server timestamp in the future.
    final onlineStart = seen
        .subtract(const Duration(seconds: 70))
        .add(const Duration(microseconds: 1));
    return online &&
            onlineStart.isAfter(now) &&
            onlineStart.isBefore(labelChange)
        ? onlineStart
        : labelChange;
  }

  bool isOnlineAt(DateTime now) =>
      online &&
      lastSeen != null &&
      now.difference(lastSeen!).abs() < const Duration(seconds: 70);
  String textAt(DateTime now) {
    if (isOnlineAt(now)) return 'В сети';
    final seen = lastSeen;
    if (seen == null) return 'Не в сети';
    final age = now.difference(seen);
    if (age.inMinutes < 1) return 'Был(а) только что';
    if (age.inMinutes < 60) return 'Был(а) ${age.inMinutes} мин назад';
    if (age.inHours < 24) return 'Был(а) ${age.inHours} ч назад';
    return 'Был(а) ${age.inDays} дн назад';
  }
}

class ChatActivity {
  const ChatActivity(this.state, this.updatedAt);
  final String state;
  final DateTime? updatedAt;
  DateTime? nextChangeAt(DateTime now) {
    final updated = updatedAt;
    if (updated == null || (state != 'typing' && state != 'recording')) {
      return null;
    }
    if (textAt(now) != null) return updated.add(const Duration(seconds: 8));
    final start = updated
        .subtract(const Duration(seconds: 8))
        .add(const Duration(microseconds: 1));
    return start.isAfter(now) ? start : null;
  }

  String? textAt(DateTime now) {
    if (updatedAt == null ||
        now.difference(updatedAt!).abs() >= const Duration(seconds: 8)) {
      return null;
    }
    return switch (state) {
      'recording' => 'Записывает голосовое…',
      'typing' => 'Печатает…',
      _ => null,
    };
  }
}

/// Short-lived activity contains no message text or audio.
class PresenceService extends ChangeNotifier {
  PresenceService._();
  static final instance = PresenceService._();
  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  String? _owner;
  bool _foreground = true;
  bool _refreshing = false;
  RealtimeChannel? _channel;
  Timer? _heartbeat;
  Timer? _poll;
  Timer? _expiry;
  final _presence = <String, UserPresence>{};
  final _activity = <String, ChatActivity>{};
  Map<String, (bool, String, String)> _displayed = {};
  Future<void> _writes = Future.value();

  void _updateVisibleStatuses() {
    _expiry?.cancel();
    _expiry = null;
    if (!_foreground || _owner == null) return;
    final now = DateTime.now();
    final displayed = <String, (bool, String, String)>{};
    DateTime? next;
    for (final id in {..._presence.keys, ..._activity.keys}) {
      final presence = _presence[id] ?? const UserPresence(false, null);
      final activity = _activity[id];
      final status = presence.textAt(now);
      displayed[id] = (
        presence.isOnlineAt(now),
        status,
        activity?.textAt(now) ?? status,
      );
      for (final date in [
        presence.nextChangeAt(now),
        activity?.nextChangeAt(now),
      ]) {
        if (date != null &&
            date.isAfter(now) &&
            (next == null || date.isBefore(next))) {
          next = date;
        }
      }
    }
    if (!mapEquals(_displayed, displayed)) {
      _displayed = displayed;
      notifyListeners();
    }
    if (next != null) {
      _expiry = Timer(next.difference(now), _updateVisibleStatuses);
    }
  }

  String statusText(String id) =>
      (_presence[id] ?? const UserPresence(false, null)).textAt(DateTime.now());
  bool isOnline(String id) =>
      _presence[id]?.isOnlineAt(DateTime.now()) ?? false;
  String chatStatus(String id) =>
      _activity[id]?.textAt(DateTime.now()) ?? statusText(id);

  void start() {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null || id == _owner) return;
    stop();
    _owner = id;
    _foreground = true;
    _channel = client
        .channel('activity_$id')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'user_presence',
          callback: (_) => unawaited(refresh()),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_activity',
          callback: (_) => unawaited(refresh()),
        )
        .subscribe((status, error) {
          if (status == RealtimeSubscribeStatus.subscribed) {
            unawaited(refresh());
          }
        });
    unawaited(_pulse());
    unawaited(refresh());
    _heartbeat = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_foreground) unawaited(_pulse());
    });
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_foreground) unawaited(refresh());
    });
  }

  void setForeground(bool value) {
    _foreground = value;
    _updateVisibleStatuses();
    unawaited(_pulse());
    if (value) unawaited(refresh());
  }

  Future<void> _pulse() async {
    final id = _owner;
    final client = _client;
    if (id == null || client?.auth.currentUser?.id != id) return;
    try {
      await client!
          .from('user_presence')
          .upsert({'user_id': id, 'online': _foreground})
          .timeout(const Duration(seconds: 8));
    } catch (error) {
      debugPrint('[Presence] heartbeat failed: $error');
    }
  }

  DateTime? _lastRefreshAt;

  Future<void> refresh() async {
    final id = _owner;
    final client = _client;
    if (id == null || client?.auth.currentUser?.id != id || _refreshing) return;
    // Realtime-события от каждого друга и 10-секундный опрос дублируют друг
    // друга: подряд идущие обновления схлопываются в одно (данные всё равно
    // стареют за секунды).
    final now = DateTime.now();
    if (_lastRefreshAt != null &&
        now.difference(_lastRefreshAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastRefreshAt = now;
    _refreshing = true;
    try {
      final rows = await client!
          .from('user_presence')
          .select()
          .timeout(const Duration(seconds: 10));
      final activity = await client
          .from('chat_activity')
          .select()
          .eq('peer_id', id)
          .timeout(const Duration(seconds: 10));
      if (_owner != id) return;
      _presence.clear();
      for (final row in rows) {
        _presence[row['user_id'].toString()] = UserPresence(
          row['online'] == true,
          DateTime.tryParse(row['last_seen']?.toString() ?? ''),
        );
      }
      _activity.clear();
      for (final row in activity) {
        _activity[row['user_id'].toString()] = ChatActivity(
          row['state'].toString(),
          DateTime.tryParse(row['updated_at']?.toString() ?? ''),
        );
      }
      _updateVisibleStatuses();
    } catch (error) {
      debugPrint('[Presence] refresh failed: $error');
    } finally {
      _refreshing = false;
    }
  }

  Future<void> setChatState(String peerId, String state) {
    final id = _owner;
    final client = _client;
    if (id == null || client?.auth.currentUser?.id != id) return Future.value();
    _writes = _writes.then((_) async {
      if (_owner != id || client!.auth.currentUser?.id != id) return;
      try {
        await client
            .from('chat_activity')
            .upsert({
              'user_id': id,
              'peer_id': peerId,
              'state': state,
            }, onConflict: 'user_id,peer_id')
            .timeout(const Duration(seconds: 8));
      } catch (error) {
        debugPrint('[Presence] chat activity failed: $error');
      }
    });
    return _writes;
  }

  void stop() {
    final id = _owner;
    if (id != null && _client?.auth.currentUser?.id == id) {
      unawaited(
        _client!
            .from('user_presence')
            .update({'online': false})
            .eq('user_id', id)
            .timeout(const Duration(seconds: 8))
            .then((_) {}, onError: (Object _) {}),
      );
    }
    _owner = null;
    _heartbeat?.cancel();
    _poll?.cancel();
    _expiry?.cancel();
    _expiry = null;
    _lastRefreshAt = null;
    _displayed = {};
    final channel = _channel;
    _channel = null;
    if (channel != null) unawaited(channel.unsubscribe());
    _presence.clear();
    _activity.clear();
  }
}
