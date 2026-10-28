import '../models/activity_type.dart';

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preserve complete originals before lossy migration. A cache hit is not proof
/// that the platform confirmed a previous backup write.
abstract final class LocalDataIntegrity {
  static Future<void> preserve(
    SharedPreferences prefs,
    String key,
    String raw,
  ) async {
    final digest = sha256.convert(utf8.encode(raw));
    if (!await prefs.setString('${key}_damaged_$digest', raw)) {
      throw StateError(
        'Не удалось сохранить резервную копию. Исходные данные не изменены.',
      );
    }
  }

  static bool retains(Object? raw, Object? normalized) {
    if (raw == null)
      return true; // Explicit optional null may acquire defaults.
    if (raw is Map) {
      if (normalized is! Map) return false;
      return raw.entries.every(
        (e) =>
            normalized.containsKey(e.key) &&
            retains(e.value, normalized[e.key]),
      );
    }
    if (raw is List) {
      if (normalized is! List || raw.length != normalized.length) return false;
      for (var i = 0; i < raw.length; i++) {
        if (!retains(raw[i], normalized[i])) return false;
      }
      return true;
    }
    return raw == normalized;
  }

  static bool routeChanged(Map raw, Map normalized) {
    final comparable = Map.of(raw);
    final legacy =
        raw['activityIndex'] ??
        (raw['activityType'] is int ? raw['activityType'] : null);
    if (legacy is int &&
        legacy >= 0 &&
        legacy < ActivityType.values.length &&
        normalized['activityType'] == ActivityType.values[legacy].name) {
      comparable.remove('activityIndex');
      if (raw['activityType'] is int) comparable.remove('activityType');
    }
    final oldDate = raw['createdAt'], newDate = normalized['createdAt'];
    if (newDate is String) {
      final before = oldDate is num
          ? DateTime.fromMillisecondsSinceEpoch(oldDate.toInt())
          : DateTime.tryParse(oldDate?.toString() ?? '');
      if (before != null && before == DateTime.tryParse(newDate))
        comparable.remove('createdAt');
    }
    return !retains(comparable, normalized);
  }

  static bool unknownKeys(Map raw, Set<String> known) =>
      raw.keys.any((k) => !known.contains(k));
}
