import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'user_scope.dart';

/// Disposable UI snapshots, separate from the authoritative local ride history.
class UiSnapshotCache {
  const UiSnapshotCache(this.name, this.owner);
  final String name;
  final String? owner;
  String get key => UserScope.keyFor('ui_snapshot_v1_$name', owner);

  Future<List<Map<String, dynamic>>?> read({
    DateTime? now,
    bool allowStale = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final date = DateTime.parse(data['saved_at'] as String);
      final age = (now ?? DateTime.now()).difference(date);
      if (age.isNegative || (!allowStale && age > const Duration(hours: 24)))
        return null;
      return (data['rows'] as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> write(List<Map<String, dynamic>> rows, {DateTime? now}) async {
    try {
      final raw = jsonEncode({
        'saved_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
        'rows': rows.take(100).toList(),
      });
      if (raw.length > 500000) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, raw);
    } catch (_) {
      // A disposable cache must never prevent loading network data.
    }
  }
}
