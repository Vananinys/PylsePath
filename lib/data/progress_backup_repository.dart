import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'user_scope.dart';

/// Private progress backup, never a source of owner-granted privileges.
class ProgressBackupRemote {
  Future<Map<String, dynamic>> exchange(
    String owner,
    Map<String, dynamic> state,
  ) async {
    final client = Supabase.instance.client;
    if (client.auth.currentUser?.id != owner)
      throw StateError('Account changed');
    final response = await client
        .rpc('sync_private_progress', params: {'p_state': state})
        .timeout(const Duration(seconds: 12));
    if (client.auth.currentUser?.id != owner)
      throw StateError('Account changed');
    return Map<String, dynamic>.from(response as Map);
  }
}

class ProgressBackupRepository {
  static final Map<String, ProgressBackupRepository> _instances = {};
  @visibleForTesting
  static void resetInstancesForTesting() => _instances.clear();
  factory ProgressBackupRepository() {
    final owner = UserScope.currentUserId();
    return _instances.putIfAbsent(
      owner ?? 'guest',
      () => ProgressBackupRepository._(
        owner,
        UserScope.currentUserId,
        ProgressBackupRemote(),
      ),
    );
  }
  ProgressBackupRepository._(this.owner, this._ownerResolver, this._remote);
  @visibleForTesting
  factory ProgressBackupRepository.forTesting({
    required String owner,
    required String? Function() currentOwner,
    required ProgressBackupRemote remote,
  }) => ProgressBackupRepository._(owner, currentOwner, remote);
  final String? owner;
  final String? Function() _ownerResolver;
  final ProgressBackupRemote _remote;
  Future<void> _tail = Future.value();
  Future<void>? _sync;
  bool get _current => _ownerResolver() == owner;
  String get _key => UserScope.keyFor('progress_backup_v1', owner);
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  static Map<String, dynamic> merge(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final days = <String, int>{};
    final unlocked = <String, dynamic>{};
    var preferences = <String, dynamic>{};
    for (final source in [a, b]) {
      for (final e in (source['days'] as Map? ?? {}).entries) {
        if (e.key is! String ||
            !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(e.key) ||
            e.value is! num ||
            !(e.value as num).isFinite ||
            (e.value as num) < 0)
          continue;
        final value = (e.value as num).toInt().clamp(0, 500000);
        if (value > (days[e.key] ?? -1)) days[e.key] = value;
      }
      for (final e in (source['unlocked'] as Map? ?? {}).entries) {
        if (e.key is String &&
            (e.key as String).startsWith('builtin:') &&
            e.value is Map) {
          // First receipt wins, so a later sync cannot change the earned date.
          unlocked.putIfAbsent(e.key, () => Map<String, dynamic>.from(e.value));
        }
      }
      final next = Map<String, dynamic>.from(
        source['preferences'] as Map? ?? {},
      );
      if ((preferences.isEmpty && next.isNotEmpty) ||
          (next['updatedAt'] as num? ?? 0) >
              (preferences['updatedAt'] as num? ?? 0)) {
        preferences = next;
      }
    }
    return {
      'days': {for (final k in days.keys.toList()..sort()) k: days[k]},
      'unlocked': {
        for (final k in unlocked.keys.toList()..sort()) k: unlocked[k],
      },
      'preferences': preferences,
    };
  }

  Future<Map<String, dynamic>> _read() async {
    if (!_current) throw StateError('Account changed');
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (!_current) throw StateError('Account changed');
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map)
        throw const FormatException('Invalid backup envelope');
      return Map<String, dynamic>.from(decoded);
    } on FormatException {
      // Keep the unreadable original before recovering from the server.
      if (!await prefs.setString(
        '${_key}_damaged_${DateTime.now().millisecondsSinceEpoch}',
        raw,
      )) {
        throw StateError('Не удалось сохранить исходную повреждённую копию');
      }
      return {};
    }
  }

  Future<void> _write(Map<String, dynamic> state) async {
    if (!_current) throw StateError('Account changed');
    final prefs = await SharedPreferences.getInstance();
    if (!_current || !await prefs.setString(_key, jsonEncode(state))) {
      throw StateError('Не удалось сохранить резервную копию');
    }
  }

  Future<Map<String, dynamic>> read() => _serial(_read);
  Future<void> update(Map<String, dynamic> change) => _serial(() async {
    final previous = await _read();
    final next = merge(previous, change);
    final changed = jsonEncode(merge({}, previous)) != jsonEncode(next);
    await _write({...previous, ...next, if (changed) 'pending': true});
  });
  Future<void> sync() {
    if (owner == null || !_current) return Future.value();
    return _sync ??= _exchange().whenComplete(() => _sync = null);
  }

  Future<void> _exchange() async {
    final sent = merge({}, await read());
    // Network never holds the local write queue: offline saves stay immediate.
    final received = await _remote.exchange(owner!, sent);
    await _serial(() async {
      final latest = await _read();
      final changedDuringUpload =
          jsonEncode(merge({}, latest)) != jsonEncode(sent);
      final merged = merge(latest, received);
      // Old migrations have timestamp zero. An acknowledged server copy wins
      // that tie on a new device, while edits made during upload stay pending.
      final remotePreferences = received['preferences'] as Map? ?? {};
      final localPreferences = latest['preferences'] as Map? ?? {};
      if (!changedDuringUpload &&
          remotePreferences.isNotEmpty &&
          (remotePreferences['updatedAt'] as num? ?? 0) >=
              (localPreferences['updatedAt'] as num? ?? 0)) {
        merged['preferences'] = remotePreferences;
      }
      await _write({
        ...merged,
        'pending': changedDuringUpload,
        'cloudSyncedAt': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }
}
