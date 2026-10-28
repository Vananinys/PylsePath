import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_route.dart';
import '../models/workout_details.dart';
import '../services/rides_service.dart';
import '../services/garage_service.dart';
import '../services/achievements_service.dart';
import 'user_scope.dart';
import 'progress_backup_repository.dart';
import '../services/workout_step_tracker.dart';
import '../services/recording_daily_activity_service.dart';
import '../models/walking_steps.dart';
import '../models/ride_moment.dart';

class WorkoutHistoryRepository {
  static final Map<String, WorkoutHistoryRepository> _instances = {};

  /// Isolate widget-test fake-async zones. Never call while real operations are active.
  @visibleForTesting
  static void resetInstancesForTesting() {
    _instances.clear();
    // Both reset entrypoints are test-only; clear queues across test zones.
    // ignore: invalid_use_of_visible_for_testing_member
    ProgressBackupRepository.resetInstancesForTesting();
  }

  factory WorkoutHistoryRepository() {
    final uid = UserScope.currentUserId();
    final key = UserScope.keyFor('workout_history', uid);
    return _instances.putIfAbsent(
      key,
      () => WorkoutHistoryRepository._(uid, key),
    );
  }
  WorkoutHistoryRepository._(this._owner, this._key);
  final String? _owner;
  final String _key;
  final RidesService _ridesService = RidesService();
  List<SavedRoute> _workoutHistory = [];
  final Set<String> _deletedIds = {};
  final Set<String> _pendingDeletes = {};
  Future<void> _tail = Future.value();
  bool _historyReadFailed = false;
  bool _usingRecoveryStore = false;
  String? recoveryNotice;
  String get _recoveryKey => '${_key}_recovery_v1';
  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  List<SavedRoute> get workoutHistory => List.unmodifiable(_workoutHistory);
  List<SavedRoute> get unsyncedWorkouts =>
      _workoutHistory.where((r) => !r.cloudSynced).toList();
  bool get hasPendingSync =>
      _pendingDeletes.isNotEmpty || _workoutHistory.any((r) => !r.cloudSynced);
  void _requireOwner() {
    if (UserScope.currentUserId() != _owner)
      throw StateError('Аккаунт истории изменился. Откройте историю заново.');
  }

  // Detect discarded values, including unknown fields from a newer version.
  // Added defaults are harmless, but every original value must remain recoverable.
  static bool _retainsOriginal(Object? raw, Object? normalized) {
    if (raw is Map) {
      if (normalized is! Map) return false;
      return raw.entries.every(
        (entry) =>
            normalized.containsKey(entry.key) &&
            _retainsOriginal(entry.value, normalized[entry.key]),
      );
    }
    if (raw is List) {
      if (normalized is! List || raw.length != normalized.length) return false;
      for (var i = 0; i < raw.length; i++) {
        if (!_retainsOriginal(raw[i], normalized[i])) return false;
      }
      return true;
    }
    return raw == normalized;
  }

  static bool _telemetryChanged(Map row) {
    final raw = row['workoutDetails'];
    return raw != null &&
        !_retainsOriginal(raw, WorkoutDetails.fromJson(raw).toJson());
  }

  Future<void> _read() async {
    _requireOwner();
    _usingRecoveryStore = false;
    recoveryNotice = null;
    var primaryDamaged = false;
    try {
      await _readPrimary();
    } on FormatException {
      primaryDamaged = true;
      // The original and its digest backup remain untouched. Only the recovery
      // archive is writable until an explicit repair is possible.
      // Retain the last known valid in-memory snapshot, if available.
    }
    final prefs = await SharedPreferences.getInstance();
    _requireOwner();
    final recovery = prefs.getString(_recoveryKey);
    if (!primaryDamaged && recovery == null) return;
    _usingRecoveryStore = true;
    if (primaryDamaged) {
      recoveryNotice = 'Часть прежней истории не читается. Оригинал сохранён. Новые поездки сохраняются отдельно.';
    }
    if (recovery != null) {
      try {
        final envelope = Map<String, dynamic>.from(jsonDecode(recovery) as Map);
        if (envelope['version'] != 2)
          throw const FormatException('Unknown recovery version');
        if ((envelope['workouts'] as List).any(
          (row) => _telemetryChanged(row as Map),
        )) {
          await _preserveDamaged(prefs, recovery, key: _recoveryKey);
        }
        final routes = (envelope['workouts'] as List)
            .map(
              (r) => SavedRoute.fromJson(Map<String, dynamic>.from(r as Map)),
            )
            .toList();
        final deleted = (envelope['deletedIds'] as List? ?? []).cast<String>();
        final pending = (envelope['pendingDeletes'] as List? ?? [])
            .cast<String>();
        final merged = {
          for (final route in _workoutHistory) route.localId: route,
          for (final route in routes) route.localId: route,
        };
        _deletedIds.addAll(deleted);
        _pendingDeletes.addAll(pending);
        _workoutHistory = merged.values
            .where(
              (r) =>
                  !_deletedIds.contains(r.localId) &&
                  (r.remoteId == null || !_deletedIds.contains(r.remoteId)),
            )
            .toList();
      } catch (_) {
        _historyReadFailed = true;
        final backup =
            '${_recoveryKey}_damaged_${sha256.convert(utf8.encode(recovery))}';
        if (!await prefs.setString(backup, recovery)) {
          throw StateError(
            'Не удалось сохранить резервную копию дополнительной истории.',
          );
        }
        throw const FormatException(
          'Дополнительная история повреждена. Исходник сохранён; требуется восстановление.',
        );
      }
    }
    _historyReadFailed = false;
  }

  Future<void> _readPrimary() async {
    _historyReadFailed = true;
    final prefs = await SharedPreferences.getInstance();
    _requireOwner();
    final text = prefs.getString(_key);
    if (text == null) {
      _workoutHistory = [];
      _deletedIds.clear();
      _pendingDeletes.clear();
      _historyReadFailed = false;
      return;
    }
    // One JSON envelope keeps history and deletion outbox in one storage write.
    // Legacy versions stored just a list and remain readable.
    List rows;
    var migratedFromLegacy = false;
    final deletedIds = <String>{};
    final pendingDeletes = <String>{};
    final parsed = <SavedRoute>[];
    var needsPersist = false;
    var needsTelemetryBackup = false;
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) {
        rows = decoded;
        migratedFromLegacy = true;
      } else {
        final envelope = Map<String, dynamic>.from(decoded as Map);
        if (envelope['version'] != 2) {
          throw const FormatException('Неизвестная версия истории');
        }
        rows = envelope['workouts'] as List;
        deletedIds.addAll(
          (envelope['deletedIds'] as List? ?? const []).cast<String>(),
        );
        pendingDeletes.addAll(
          (envelope['pendingDeletes'] as List? ?? const []).cast<String>(),
        );
      }
      needsPersist = migratedFromLegacy;
      for (final row in rows) {
        final map = Map<String, dynamic>.from(row as Map);
        if (map['localId'] is! String && map['remoteId'] is! String) {
          needsPersist = true;
        }
        parsed.add(SavedRoute.fromJson(map));
        if (_telemetryChanged(map)) needsTelemetryBackup = true;
      }
    } catch (error) {
      // Never replace unreadable history with an empty or partial list.
      // Keep the last valid in-memory snapshot and protect every write path.
      await _preserveDamaged(prefs, text);
      throw const FormatException(
        'История повреждена. Исходные данные сохранены без изменений; требуется восстановление.',
      );
    }
    if (needsTelemetryBackup) await _preserveDamaged(prefs, text);
    _deletedIds
      ..clear()
      ..addAll(deletedIds);
    _pendingDeletes
      ..clear()
      ..addAll(pendingDeletes);
    _workoutHistory = parsed;
    final countBeforeFilter = _workoutHistory.length;
    _workoutHistory.removeWhere(
      (r) =>
          _deletedIds.contains(r.localId) ||
          (r.remoteId != null && _deletedIds.contains(r.remoteId)),
    );
    if (_workoutHistory.length != countBeforeFilter) needsPersist = true;
    _historyReadFailed = false;
    // Only valid complete histories may be migrated and written back.
    if (needsPersist) await _write();
  }

  Future<void> _preserveDamaged(
    SharedPreferences prefs,
    String text, {
    String? key,
  }) async {
    final digest = sha256.convert(utf8.encode(text));
    final backupKey = '${key ?? _key}_damaged_$digest';
    // Confirm on the platform: an optimistic preferences cache is not a backup.
    if (!await prefs.setString(backupKey, text)) {
      throw StateError(
        'Не удалось сохранить резервную копию. История не изменена.',
      );
    }
  }

  Future<void> _write() async {
    _requireOwner();
    if (_historyReadFailed) {
      throw StateError('Запись заблокирована до восстановления истории.');
    }
    final prefs = await SharedPreferences.getInstance();
    _requireOwner();
    final ok = await prefs.setString(
      _usingRecoveryStore ? _recoveryKey : _key,
      jsonEncode({
        'version': 2,
        'workouts': _workoutHistory.map((r) => r.toJson()).toList(),
        'deletedIds': _deletedIds.toList(),
        'pendingDeletes': _pendingDeletes.toList(),
      }),
    );
    if (!ok) throw StateError('Не удалось записать историю на устройство');
  }

  Future<void> load() => _serial(_read);
  Future<void> save() => _serial(() async {
    await _read();
    await _write();
  });
  Future<void> addWorkout(SavedRoute workout) => _serial(() async {
    await _read();
    if (!_workoutHistory.any((r) => r.localId == workout.localId)) {
      _workoutHistory.add(workout);
      await _write();
      if (UserScope.currentUserId() == _owner && recoveryNotice == null) {
        await AchievementsService.captureProgress(_workoutHistory);
      }
    }
  });
  Future<void> replaceRoute(SavedRoute oldRoute, SavedRoute newRoute) =>
      _serial(() async {
        await _read();
        final index = _workoutHistory.indexWhere(
          (r) => r.localId == oldRoute.localId,
        );
        if (index < 0) return;
        _workoutHistory[index] = newRoute;
        await _write();
      });
  Future<void> removeWorkout(SavedRoute workout) => _serial(() async {
    await _read();
    _deletedIds.add(workout.localId);
    _deletedIds.add(workout.remoteId ?? workout.localId);
    // Even an unacknowledged upload may already exist remotely.
    _pendingDeletes.add(workout.remoteId ?? workout.localId);
    _workoutHistory.removeWhere((r) => r.localId == workout.localId);
    await _write();
  });

  /// Merge against the latest local row, so a new note cannot overwrite steps
  /// reconciled while the detail screen was open. Upload follows the usual queue.
  Future<SavedRoute> addRideMoment(SavedRoute route, RideMoment moment) =>
      _serial(() async {
        await _read();
        if (UserScope.currentUserId() != _owner) {
          throw StateError('Аккаунт изменился. Откройте заезд заново.');
        }
        final index = _workoutHistory.indexWhere(
          (r) => r.localId == route.localId,
        );
        if (index < 0) throw StateError('Заезд не найден в вашей истории.');
        final current = _workoutHistory[index];
        final moments = current.workoutDetails.rideMoments;
        if (moment.pointIndex >= current.routePoints.length ||
            RideMoment.tryParse(moment.toJson()) == null) {
          throw StateError('Невозможно сохранить отметку вне трека.');
        }
        if (moments.any((m) => m.id == moment.id)) return current;
        if (moments.length >= 200)
          throw StateError('В заезде уже есть 200 отметок.');
        final json = current.toJson();
        json['workoutDetails'] = {
          ...current.workoutDetails.toJson(),
          'ride_moments': [...moments, moment].map((m) => m.toJson()).toList(),
        };
        json['cloudSynced'] = false;
        final updated = SavedRoute.fromJson(json);
        _workoutHistory[index] = updated;
        await _write();
        return updated;
      });
  Future<void> clear() => _serial(() async {
    await _read();
    for (final r in _workoutHistory) {
      _deletedIds.add(r.localId);
      _deletedIds.add(r.remoteId ?? r.localId);
      _pendingDeletes.add(r.remoteId ?? r.localId);
    }
    _workoutHistory = [];
    await _write();
  });
  Future<List<SavedRoute>> getWorkoutHistory() async {
    await load();
    return workoutHistory;
  }

  Future<void>? _restoring;
  Future<int>? _stepReconciliation;
  DateTime? _lastStepReconciliation;
  Future<int> reconcileWalkingSteps() => _stepReconciliation ??=
      _reconcileWalkingSteps().whenComplete(() => _stepReconciliation = null);
  Future<int> _reconcileWalkingSteps() async {
    final platform = StepRecordingPlatform();
    if (!platform.supported ||
        _owner == null ||
        UserScope.currentUserId() != _owner)
      return 0;
    final now = DateTime.now();
    if (_lastStepReconciliation != null &&
        now.difference(_lastStepReconciliation!) < const Duration(minutes: 2))
      return 0;
    _lastStepReconciliation = now;
    final device = await WorkoutStepTracker.localDevice();
    await load();
    final candidates = workoutHistoryDesc
        .where((r) {
          final steps = r.workoutDetails.walkingSteps;
          return steps != null &&
              steps.device == device &&
              steps.windows.isNotEmpty &&
              steps.windows.every((w) => w.end != null) &&
              now.millisecondsSinceEpoch - steps.windows.last.end! <
                  const Duration(days: 1).inMilliseconds;
        })
        .take(2)
        .toList();
    var changed = 0;
    for (final ride in candidates) {
      try {
        if (UserScope.currentUserId() != _owner) break;
        final old = ride.workoutDetails.walkingSteps!;
        final response = await platform
            .invoke('workoutSteps', {
              'owner': _owner,
              'windows': [
                for (final w in old.windows) {'start': w.start, 'end': w.end},
              ],
            })
            .timeout(const Duration(seconds: 35));
        if (UserScope.currentUserId() != _owner) break;
        final counts = response['totals'];
        if (counts is! List || counts.length != old.windows.length) continue;
        changed += await _serial(() async {
          await _read();
          final index = _workoutHistory.indexWhere(
            (r) => r.localId == ride.localId,
          );
          if (index < 0 || UserScope.currentUserId() != _owner) return 0;
          final current = _workoutHistory[index],
              steps = current.workoutDetails.walkingSteps;
          if (steps == null ||
              steps.device != device ||
              steps.windows.length != old.windows.length)
            return 0;
          final windows = <StepWindow>[];
          for (var i = 0; i < steps.windows.length; i++) {
            final w = steps.windows[i];
            if (w.start != old.windows[i].start || w.end != old.windows[i].end)
              return 0;
            final n = counts[i];
            final total = n is num && n.isFinite
                ? n.toInt().clamp(0, 500000)
                : 0;
            windows.add(
              StepWindow(
                start: w.start,
                end: w.end,
                recorded: total > w.recorded ? total : w.recorded,
                live: w.live,
              ),
            );
          }
          final merged = WalkingSteps(
            device: device,
            windows: windows,
            observedAt: now.millisecondsSinceEpoch,
            stride: steps.stride,
          );
          if (merged.count <= steps.count) return 0;
          final json = current.toJson();
          json['workoutDetails'] = {
            ...current.workoutDetails.toJson(),
            'walking_steps': merged.toJson(),
          };
          json['cloudSynced'] = false;
          _workoutHistory[index] = SavedRoute.fromJson(json);
          await _write();
          return 1;
        });
      } catch (error) {
        debugPrint('[WorkoutSteps] postponed: ${error.runtimeType}');
      }
    }
    if (changed > 0 && UserScope.currentUserId() == _owner)
      await retryUnsynced(maxItems: 2);
    return changed;
  }

  Future<void> restoreFromCloud() =>
      _restoring ??= _restoreCloud().whenComplete(() => _restoring = null);
  Future<void> _restoreCloud() async {
    await load();
    if (_owner == null || UserScope.currentUserId() != _owner) return;
    final remote = await _ridesService
        .fetchRides(throwOnError: true)
        .timeout(const Duration(seconds: 12));
    if (UserScope.currentUserId() != _owner) return;
    // Restoration is additive; an empty/partial response never erases history.
    await mergeRemote(remote);
    if (UserScope.currentUserId() == _owner && recoveryNotice == null) {
      await AchievementsService.captureProgress(_workoutHistory);
    }
  }

  List<SavedRoute> get workoutHistoryDesc {
    final rows = List<SavedRoute>.from(_workoutHistory)
      ..sort((a, b) => b.dateTime.compareTo(a.dateTime));
    return List.unmodifiable(rows);
  }

  static bool _isSameRide(SavedRoute a, SavedRoute b) {
    if (a.localId == b.localId) return true;
    if (a.remoteId != null && b.remoteId != null) {
      return a.remoteId == b.remoteId;
    }
    // Compatibility only for already-synced legacy rows, never pending rides.
    if (!a.cloudSynced || !b.cloudSynced) return false;
    return a.dateTime.difference(b.dateTime).inSeconds.abs() < 60 &&
        (a.distanceKm - b.distanceKm).abs() < 0.01;
  }

  Future<int> mergeRemote(
    List<SavedRoute> remote, {
    bool completeSnapshot = false,
  }) => _serial(() async {
    await _read();
    // Damaged tombstones cannot safely authorize a cloud restore.
    if (recoveryNotice != null) return 0;
    var added = 0;
    var changed = false;
    if (completeSnapshot) {
      // The caller may reconcile deletions only after a successful,
      // fully paginated cloud read. Keep local rides still waiting to upload.
      final before = _workoutHistory.length;
      _workoutHistory.removeWhere(
        (local) =>
            local.cloudSynced && !remote.any((row) => _isSameRide(local, row)),
      );
      changed = _workoutHistory.length != before;
    }
    for (final row in remote) {
      if (_deletedIds.contains(row.localId) ||
          _deletedIds.contains(row.remoteId)) {
        continue;
      }
      final existing = _workoutHistory.indexWhere(
        (local) => _isSameRide(local, row),
      );
      if (existing < 0) {
        _workoutHistory.add(row);
        added++;
      } else {
        final local = _workoutHistory[existing];
        final localIds = local.workoutDetails.rideMoments
            .map((m) => m.id)
            .toSet();
        final remoteIds = row.workoutDetails.rideMoments
            .map((m) => m.id)
            .toSet();
        final newMoments = row.workoutDetails.rideMoments
            .where(
              (m) =>
                  !localIds.contains(m.id) &&
                  m.pointIndex < local.routePoints.length,
            )
            .toList();
        final needsUpload = localIds.any((id) => !remoteIds.contains(id));
        if (newMoments.isNotEmpty || (local.cloudSynced && needsUpload)) {
          final json = local.toJson();
          json['workoutDetails'] = {
            ...local.workoutDetails.toJson(),
            'ride_moments': [
              ...local.workoutDetails.rideMoments,
              ...newMoments,
            ].map((m) => m.toJson()).toList(),
          };
          json['cloudSynced'] = local.cloudSynced && !needsUpload;
          _workoutHistory[existing] = SavedRoute.fromJson(json);
          changed = true;
        }
      }
    }
    if (added > 0 || changed) await _write();
    return added;
  });

  /// Each batch is bounded; already uploaded rides are never resent. A failed
  /// delete only stops further deletes this run — the id stays pending for the
  /// next sync window and must not block uploading offline rides.
  Future<int> retryUnsynced({int maxItems = 10}) => _serial(() async {
    await _read();
    if (_owner == null || UserScope.currentUserId() != _owner) return 0;
    var attempted = 0;
    final limit = maxItems.clamp(1, 25);
    for (final id in _pendingDeletes.toList().take(limit)) {
      if (UserScope.currentUserId() != _owner) break;
      attempted++;
      if (await _ridesService.deleteRide(id, expectedUserId: _owner)) {
        _pendingDeletes.remove(id);
        await _write();
      } else {
        break;
      }
    }
    var synced = 0;
    for (var i = 0; i < _workoutHistory.length; i++) {
      final route = _workoutHistory[i];
      if (route.cloudSynced) continue;
      if (attempted >= limit || UserScope.currentUserId() != _owner) break;
      attempted++;
      final id = await _ridesService.saveRide(
        workoutDetails: {
          ...route.workoutDetails.toJson(),
          'title': route.title,
          if (route.activityLocalDay != null)
            'activity_local_day': route.activityLocalDay,
        },
        rideId: route.localId,
        expectedUserId: _owner,
        distanceKm: route.distanceKm,
        durationSeconds:
            route.durationSeconds ?? (route.durationMin * 60).round(),
        calories: route.calories,
        elevationGain: route.elevationGainMeters,
        trackPoints: route.routePoints,
        vehicleId: route.vehicleId,
        transportType: route.transportType ?? route.activityType.name,
        createdAt: route.dateTime,
      );
      // Обновляем состояние синхронизации после успешного сохранения в облако
      if (UserScope.currentUserId() != _owner) break;
      if (id != null) {
        _workoutHistory[i] = route.withSyncState(
          remoteId: id,
          cloudSynced: true,
        );
        await _write();
        synced++;
      } else {
        break;
      }
    }
    debugPrint('[WorkoutHistory] synced=$synced');
    if (synced > 0 && UserScope.currentUserId() == _owner) {
      unawaited(GarageService().fetchVehicles());
    }
    return synced;
  });
}
