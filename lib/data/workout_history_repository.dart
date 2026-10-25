import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_route.dart';
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
  Future<void> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString(_key);
    _deletedIds.clear();
    _pendingDeletes.clear();
    if (text == null) {
      _workoutHistory = [];
      return;
    }
    // One JSON envelope keeps history and deletion outbox in one storage write.
    // Legacy versions stored just a list and remain readable.
    List rows;
    var migratedFromLegacy = false;
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
        rows = envelope['workouts'] as List? ?? const [];
        _deletedIds.addAll(
          (envelope['deletedIds'] as List? ?? const []).whereType<String>(),
        );
        _pendingDeletes.addAll(
          (envelope['pendingDeletes'] as List? ?? const []).whereType<String>(),
        );
      }
    } catch (error) {
      // Повреждённое хранилище не должно блокировать сохранение новых
      // заездов: исходный текст сохраняется рядом, история стартует заново.
      debugPrint('[WorkoutHistory] storage corrupted: $error');
      await _preserveDamaged(prefs, text);
      _workoutHistory = [];
      return;
    }
    // Одна битая запись не должна ломать всю историю: такие строки
    // пропускаются (оригинал сохраняется рядом) и выпадают при следующей
    // записи конверта.
    final parsed = <SavedRoute>[];
    var damagedRows = 0;
    var needsPersist = migratedFromLegacy;
    for (final row in rows) {
      if (row is! Map) {
        damagedRows++;
        continue;
      }
      try {
        final map = Map<String, dynamic>.from(row);
        // Строка без localId/remoteId получает новый UUID при каждом чтении —
        // персистим сразу, иначе повторная выгрузка задублирует заезд в облаке.
        if (map['localId'] is! String && map['remoteId'] is! String) {
          needsPersist = true;
        }
        parsed.add(SavedRoute.fromJson(map));
      } catch (error) {
        debugPrint('[WorkoutHistory] skip damaged ride row: $error');
        damagedRows++;
      }
    }
    if (damagedRows > 0) {
      needsPersist = true;
      await _preserveDamaged(prefs, text);
    }
    _workoutHistory = parsed;
    final countBeforeFilter = _workoutHistory.length;
    _workoutHistory.removeWhere(
      (r) =>
          _deletedIds.contains(r.localId) ||
          (r.remoteId != null && _deletedIds.contains(r.remoteId)),
    );
    if (_workoutHistory.length != countBeforeFilter) needsPersist = true;
    // Persist only when reading actually changed something (legacy migration,
    // generated UUIDs, dropped rows) — not on every read.
    if (needsPersist) await _write();
  }

  Future<void> _preserveDamaged(SharedPreferences prefs, String text) async {
    try {
      await prefs.setString('$_key' '_damaged', text);
    } catch (error) {
      debugPrint('[WorkoutHistory] damaged copy not saved: $error');
    }
  }

  Future<void> _write() async {
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setString(
      _key,
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
  Future<void> save() => _serial(_write);
  Future<void> addWorkout(SavedRoute workout) => _serial(() async {
    await _read();
    if (!_workoutHistory.any((r) => r.localId == workout.localId)) {
      _workoutHistory.add(workout);
      await _write();
      if (UserScope.currentUserId() == _owner) {
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
    if (UserScope.currentUserId() == _owner) {
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
