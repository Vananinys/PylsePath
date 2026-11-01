import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_route.dart';
import 'user_scope.dart';
import 'workout_draft_store.dart';

/// Separate, local-only evidence. No cloud, achievements, vehicle wear or XP.
class LaboratoryStore {
  LaboratoryStore(this.owner);
  final String? owner;
  Future<void> _tail = Future.value();
  Future<void> _write(String key, Map<String, dynamic> value) {
    final encoded = jsonEncode(value);
    final result = _tail.then((_) async {
      if (owner != UserScope.currentUserId())
        throw StateError('Аккаунт изменился');
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(UserScope.keyFor(key, owner), encoded)) {
        throw StateError('Не удалось сохранить лабораторную запись');
      }
    });
    _tail = result.catchError((Object _) {});
    return result;
  }

  Future<void> checkpoint(WorkoutDraft draft) =>
      _write('laboratory_checkpoint_${draft.localId}', draft.toJson());
  Future<void> save(SavedRoute route) =>
      _write('laboratory_result_${route.localId}', route.toJson());
  Future<void> closeCheckpoint(String id) =>
      _write('laboratory_closed_$id', {'closed': true});
  Future<List<WorkoutDraft>> drafts() async {
    await _tail;
    if (owner == null || owner != UserScope.currentUserId()) return [];
    final prefs = await SharedPreferences.getInstance();
    final result = <WorkoutDraft>[];
    for (final key in prefs.getKeys()) {
      if (!key.startsWith('laboratory_checkpoint_') || !key.endsWith('_$owner'))
        continue;
      final draft = WorkoutDraft.fromJson(
        Map<String, dynamic>.from(jsonDecode(prefs.getString(key)!) as Map),
        owner!,
      );
      if (key !=
          UserScope.keyFor('laboratory_checkpoint_${draft.localId}', owner))
        continue;
      if (prefs.containsKey(
            UserScope.keyFor('laboratory_result_${draft.localId}', owner),
          ) ||
          prefs.containsKey(
            UserScope.keyFor('laboratory_closed_${draft.localId}', owner),
          ))
        continue;
      result.add(draft);
    }
    result.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return result;
  }

  Future<List<SavedRoute>> results() async {
    await _tail;
    if (owner != UserScope.currentUserId())
      throw StateError('Аккаунт изменился');
    final prefs = await SharedPreferences.getInstance();
    // UserScope appends the account, so compare full generated keys below.
    final result = <SavedRoute>[];
    for (final key in prefs.getKeys()) {
      if (!key.startsWith('laboratory_result_') ||
          !key.endsWith('_${owner ?? 'guest'}'))
        continue;
      final text = prefs.getString(key);
      if (text == null) continue;
      try {
        final ride = SavedRoute.fromJson(
          Map<String, dynamic>.from(jsonDecode(text) as Map),
        );
        if (key == UserScope.keyFor('laboratory_result_${ride.localId}', owner))
          result.add(ride);
      } on FormatException {
        rethrow;
      }
    }
    result.sort((a, b) => b.dateTime.compareTo(a.dateTime));
    return result;
  }
}
