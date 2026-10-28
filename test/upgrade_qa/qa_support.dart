// Shared, test-only helpers for the upgrade/recovery compatibility audit.
//
// The platform store is the source of truth: assertions inspect its durable
// bytes, never only SharedPreferences' optimistic in-memory cache.
import 'dart:async';

import 'package:flutter/services.dart';
// Test-only fake of the platform store. A direct dependency is intentionally
// not added to pubspec.yaml.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Gate {
  final entered = Completer<void>();
  final released = Completer<void>();
}

/// In-memory SharedPreferences backend with deterministic failure injection.
class QaPreferencesStore extends InMemorySharedPreferencesStore {
  QaPreferencesStore() : super.empty();

  QaPreferencesStore.seeded(Map<String, String> values)
    : super.withData({
        for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
      });

  final Map<String, _Gate> _gates = {};
  final Set<String> _rejectedSuffixes = {};
  final Set<String> _throwingSuffixes = {};

  /// Holds a platform write open until [releaseValue] is called.
  void blockValueContaining(String sentinel) {
    _gates[sentinel] = _Gate();
  }

  Future<void> waitForEntered(String sentinel) =>
      _gates[sentinel]!.entered.future;

  void releaseValue(String sentinel) {
    final gate = _gates[sentinel];
    if (gate != null && !gate.released.isCompleted) gate.released.complete();
  }

  /// Simulates a platform that refuses a write (setValue returns false).
  void rejectWritesTo(String keySuffix) => _rejectedSuffixes.add(keySuffix);

  /// Simulates a platform write that throws (e.g. a storage I/O failure).
  void throwOnWritesTo(String keySuffix) => _throwingSuffixes.add(keySuffix);

  void allowWrites() {
    _rejectedSuffixes.clear();
    _throwingSuffixes.clear();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final text = value.toString();
    for (final entry in _gates.entries) {
      if (text.contains(entry.key)) {
        if (!entry.value.entered.isCompleted) entry.value.entered.complete();
        await entry.value.released.future;
        break;
      }
    }
    if (_throwingSuffixes.any(key.endsWith)) {
      throw PlatformException(
        code: 'qa-write-failure',
        message: 'Simulated platform write failure for $key',
      );
    }
    if (_rejectedSuffixes.any(key.endsWith)) return false;
    return super.setValue(valueType, key, value);
  }
}

/// A complete ride row in the current (v2) history shape.
///
/// Disable [newFields] to imitate a record written before the fields were
/// introduced, and pass [extra] to imitate fields added by a newer build.
Map<String, dynamic> workoutRow({
  String? localId,
  String? remoteId,
  Object? createdAt = '2026-10-01T10:00:00.000Z',
  String? activityType = 'cycling',
  int? activityIndex,
  List<List<num>> points = const [
    [55.0, 83.0],
    [55.0, 83.001],
  ],
  Map<String, dynamic>? details = const {'effort': 5},
  bool newFields = true,
  Map<String, dynamic> extra = const {},
}) {
  final finish = points.last;
  return {
    if (localId != null) 'localId': localId,
    if (remoteId != null) 'remoteId': remoteId,
    'title': 'Тестовая поездка ${localId ?? remoteId ?? 'без-id'}',
    'distance': '12.5 км',
    'duration': '45 мин',
    'surfaceSummary': 'Асфальт',
    'finishLat': finish[0],
    'finishLon': finish[1],
    'routePoints': points,
    if (activityType != null) 'activityType': activityType,
    if (activityIndex != null) 'activityIndex': activityIndex,
    'createdAt': createdAt,
    if (details != null) 'workoutDetails': details,
    if (newFields) ...{
      'distanceMeters': 12500,
      'durationSeconds': 2700,
      'calories': 300,
      'vehicleId': null,
      'transportType': null,
      'elevationGain': 42,
      'activityLocalDay': null,
      'cloudSynced': true,
    },
    ...extra,
  };
}

Map<String, dynamic> historyEnvelope(
  List<Map<String, dynamic>> workouts, {
  int version = 2,
  Map<String, dynamic> extra = const {},
}) => {
  'version': version,
  'workouts': workouts,
  'deletedIds': <String>[],
  'pendingDeletes': <String>[],
  ...extra,
};
