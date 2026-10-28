import 'local_data_integrity.dart';

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_route.dart';
import 'user_scope.dart';

class SavedRoutesRepository {
  static final Map<String, SavedRoutesRepository> _instances = {};
  @visibleForTesting
  static void resetInstancesForTesting() => _instances.clear();
  factory SavedRoutesRepository() {
    final uid = UserScope.currentUserId();
    final key = UserScope.keyFor('saved_routes', uid);
    return _instances.putIfAbsent(key, () => SavedRoutesRepository._(uid));
  }
  SavedRoutesRepository._(this._owner);
  final String? _owner;
  List<SavedRoute> _savedRoutes = [];
  Future<void> _tail = Future.value();
  String get _key => UserScope.keyFor('saved_routes', _owner);
  List<SavedRoute> get savedRoutes => List.unmodifiable(_savedRoutes);
  Future<void> _serial(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void _requireOwner() {
    if (UserScope.currentUserId() != _owner)
      throw StateError('Аккаунт изменился');
  }

  Future<void> _read() async {
    _requireOwner();
    final prefs = await SharedPreferences.getInstance();
    _requireOwner();
    final text = prefs.getString(_key);
    if (text == null) {
      _savedRoutes = [];
      return;
    }
    late List rows;
    late List<SavedRoute> parsed;
    try {
      rows = jsonDecode(text) as List;
      parsed = rows
          .map((e) => SavedRoute.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      await LocalDataIntegrity.preserve(prefs, _key, text);
      throw const FormatException(
        'Маршруты не читаются. Оригинал сохранён, перезапись заблокирована.',
      );
    }
    var changed = false, needsIds = false;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i] as Map;
      changed |= LocalDataIntegrity.routeChanged(row, parsed[i].toJson());
      needsIds |= row['localId'] is! String && row['remoteId'] is! String;
    }
    if (changed) await LocalDataIntegrity.preserve(prefs, _key, text);
    _requireOwner();
    _savedRoutes = parsed;
    // Opening a current library must not rewrite it. Only migrate missing IDs.
    if (needsIds) await _write();
  }

  Future<void> _write() async {
    if (UserScope.currentUserId() != _owner) {
      throw StateError('Аккаунт изменился');
    }
    final prefs = await SharedPreferences.getInstance();
    _requireOwner();
    if (!await prefs.setString(
      _key,
      jsonEncode(_savedRoutes.map((r) => r.toJson()).toList()),
    )) {
      throw StateError('Не удалось сохранить маршруты');
    }
  }

  Future<void> load() => _serial(_read);
  Future<void> save() => _serial(() async {
    await _read();
    await _write();
  });
  Future<void> addRoute(SavedRoute route) => _serial(() async {
    await _read();
    _savedRoutes.add(route);
    await _write();
  });
  Future<void> removeRoute(SavedRoute route) => _serial(() async {
    await _read();
    _savedRoutes.removeWhere((r) => r.localId == route.localId);
    await _write();
  });
  Future<void> updateRoute(SavedRoute route) => _serial(() async {
    await _read();
    final index = _savedRoutes.indexWhere((r) => r.localId == route.localId);
    if (index < 0) throw StateError('Маршрут больше не сохранён');
    _savedRoutes[index] = route;
    await _write();
  });
  Future<void> clear() => _serial(() async {
    await _read();
    _savedRoutes = [];
    await _write();
  });
  Future<List<SavedRoute>> getSavedRoutes() async {
    await load();
    return savedRoutes;
  }
}
