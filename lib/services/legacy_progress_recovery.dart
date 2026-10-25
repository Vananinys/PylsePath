import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/user_scope.dart';
import '../data/workout_history_repository.dart';
import '../data/progress_backup_repository.dart';
import '../models/saved_route.dart';

/// Old unowned records are imported only after the user confirms ownership.
/// Original keys are retained. Stable imported IDs make retrying safe.
class LegacyProgressRecovery {
  static const _keys = [
    'workout_history',
    'workout_history_guest',
    'daily_steps_v1',
    'daily_steps_v1_guest',
    'daily_steps_recording_v1',
    'daily_steps_recording_v1_guest',
    'progress_backup_v1_guest',
  ];
  static String _receipt(String key, String raw) =>
      sha256.convert(utf8.encode('$key:$raw')).toString();
  Future<Map<String, String>> pending() async {
    final owner = UserScope.currentUserId();
    if (owner == null) return {};
    final prefs = await SharedPreferences.getInstance();
    final imported =
        prefs.getStringList(
          UserScope.keyFor('progress_recovered_sources_v1', owner),
        ) ??
        [];
    if (UserScope.currentUserId() != owner) return {};
    return {
      for (final key in _keys)
        if (prefs.getString(key) != null &&
            !imported.contains(_receipt(key, prefs.getString(key)!)))
          key: prefs.getString(key)!,
    };
  }

  Future<int> recover({required bool confirmedOwnership}) async {
    if (!confirmedOwnership)
      throw StateError('Подтвердите, что это ваши записи');
    final owner = UserScope.currentUserId();
    if (owner == null) throw StateError('Войдите в свой аккаунт');
    final sources = await pending();
    final repository = WorkoutHistoryRepository();
    final backup = ProgressBackupRepository();
    final prefs = await SharedPreferences.getInstance();
    final marker = UserScope.keyFor('progress_recovered_sources_v1', owner);
    final imported = prefs.getStringList(marker) ?? [];
    var count = 0;
    for (final source in sources.entries) {
      if (UserScope.currentUserId() != owner)
        throw StateError('Account changed');
      final decoded = jsonDecode(source.value);
      if (source.key.startsWith('workout_history')) {
        final rows = decoded is List
            ? decoded
            : (decoded as Map)['workouts'] as List;
        for (final raw in rows) {
          if (UserScope.currentUserId() != owner)
            throw StateError('Account changed');
          final row = Map<String, dynamic>.from(raw as Map);
          final hash = sha256.convert(utf8.encode(jsonEncode(row))).toString();
          final stableId =
              '${hash.substring(0, 8)}-${hash.substring(8, 12)}-4${hash.substring(13, 16)}-a${hash.substring(17, 20)}-${hash.substring(20, 32)}';
          row['localId'] = row['remoteId'] ?? row['localId'] ?? stableId;
          row['cloudSynced'] = false;
          await repository.addWorkout(SavedRoute.fromJson(row));
          count++;
        }
      } else {
        final row = Map<String, dynamic>.from(decoded as Map);
        final days = Map<String, dynamic>.from(
          row['days'] as Map? ?? row['history'] as Map? ?? {},
        );
        if (row['day'] is String && row['steps'] is num)
          days[row['day']] = row['steps'];
        await backup.update({
          'days': days,
          'unlocked': row['unlocked'] as Map? ?? {},
          if (row['goal'] is num || row['stride'] is num)
            'preferences': {
              'goal': row['goal'] ?? 6000,
              'stride': row['stride'] ?? .7,
              'updatedAt': DateTime.now().millisecondsSinceEpoch,
            },
        });
        count += days.length;
      }
      imported.add(_receipt(source.key, source.value));
      if (UserScope.currentUserId() != owner ||
          !await prefs.setStringList(marker, imported)) {
        throw StateError('Не удалось сохранить результат восстановления');
      }
    }
    return count;
  }
}
