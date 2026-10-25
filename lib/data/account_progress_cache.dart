import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'user_scope.dart';

/// Durable offline view of the current account; successful server reads replace it.
class AccountProgressCache {
  AccountProgressCache(this.name, this.owner);
  final String name;
  final String? owner;
  String get _key => UserScope.keyFor('progress_cache_v1_$name', owner);
  bool get _current => owner != null && owner == UserScope.currentUserId();
  Future<dynamic> read() async {
    if (!_current) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      return !_current || raw == null ? null : jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(dynamic value) async {
    if (!_current) return;
    final prefs = await SharedPreferences.getInstance();
    if (_current && !await prefs.setString(_key, jsonEncode(value))) {
      throw StateError('Не удалось сохранить кэш прогресса');
    }
  }
}
