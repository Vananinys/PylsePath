import '../models/workout_details.dart';

import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/activity_type.dart';
import 'user_scope.dart';

/// A local checkpoint of an unfinished ride. Coordinates never leave this store.
class WorkoutDraft {
  const WorkoutDraft({
    this.details = const WorkoutDetails(),
    required this.ownerId,
    required this.localId,
    required this.startedAt,
    required this.activeMilliseconds,
    required this.distanceMeters,
    required this.elevationGainMeters,
    required this.activity,
    required this.path,
    this.vehicleId,
    this.isEbike = false,
  });

  final WorkoutDetails details;
  final String ownerId;
  final String localId;
  final DateTime startedAt;
  final int activeMilliseconds;
  final double distanceMeters;
  final double elevationGainMeters;
  final ActivityType activity;
  final List<LatLng> path;
  final String? vehicleId;
  final bool isEbike;

  Map<String, dynamic> toJson() => {
    'details': details.toJson(),
    'version': 1,
    'ownerId': ownerId,
    'localId': localId,
    'startedAt': startedAt.toIso8601String(),
    'activeMilliseconds': activeMilliseconds,
    'distanceMeters': distanceMeters,
    'elevationGainMeters': elevationGainMeters,
    'activity': activity.name,
    'vehicleId': vehicleId,
    'isEbike': isEbike,
    'path': path.map((point) => [point.latitude, point.longitude]).toList(),
  };

  factory WorkoutDraft.fromJson(Map<String, dynamic> json, String ownerId) {
    if (json['version'] != 1 || json['ownerId'] != ownerId) {
      throw const FormatException('Неверная версия или владелец черновика');
    }
    final id = json['localId'];
    final start = DateTime.tryParse(json['startedAt']?.toString() ?? '');
    final elapsed = json['activeMilliseconds'];
    final distance = json['distanceMeters'];
    final elevation = json['elevationGainMeters'];
    final activityName = json['activity'];
    final activity = ActivityType.values
        .where((a) => a.name == activityName)
        .firstOrNull;
    final rawPath = json['path'];
    if (id is! String ||
        id.isEmpty ||
        start == null ||
        elapsed is! int ||
        elapsed < 0 ||
        distance is! num ||
        !distance.isFinite ||
        distance < 0 ||
        elevation is! num ||
        !elevation.isFinite ||
        elevation < 0 ||
        activity == null ||
        rawPath is! List) {
      throw const FormatException('Повреждённый черновик поездки');
    }
    final points = <LatLng>[];
    for (final value in rawPath) {
      if (value is! List ||
          value.length != 2 ||
          value[0] is! num ||
          value[1] is! num) {
        throw const FormatException('Повреждённый трек поездки');
      }
      final lat = (value[0] as num).toDouble();
      final lon = (value[1] as num).toDouble();
      if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
        throw const FormatException('Некорректная точка трека');
      }
      points.add(LatLng(lat, lon));
    }
    return WorkoutDraft(
      details: WorkoutDetails.fromJson(json['details']),
      ownerId: ownerId,
      localId: id,
      startedAt: start,
      activeMilliseconds: elapsed,
      distanceMeters: distance.toDouble(),
      elevationGainMeters: elevation.toDouble(),
      activity: activity,
      path: List.unmodifiable(points),
      vehicleId: json['vehicleId'] as String?,
      isEbike: json['isEbike'] == true,
    );
  }
}

class WorkoutDraftStore {
  WorkoutDraftStore(this.ownerId);
  final String? ownerId;
  Future<void> _tail = Future.value();

  String? get _key =>
      ownerId == null ? null : UserScope.keyFor('workout_draft', ownerId);

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<WorkoutDraft?> load() => _serial(() async {
    final key = _key;
    if (key == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString(key);
    if (text == null) return null;
    return WorkoutDraft.fromJson(
      Map<String, dynamic>.from(jsonDecode(text) as Map),
      ownerId!,
    );
  });

  Future<void> save(WorkoutDraft draft) => _serial(() async {
    final key = _key;
    if (key == null || draft.ownerId != ownerId) return;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(key, jsonEncode(draft.toJson()))) {
      throw StateError('Не удалось сохранить черновик поездки');
    }
  });

  Future<void> delete() => _serial(() async {
    final key = _key;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(key)) {
      throw StateError('Не удалось удалить черновик поездки');
    }
  });
}
