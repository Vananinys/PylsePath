import '../models/workout_details.dart';

import 'dart:convert';

import 'package:crypto/crypto.dart';

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
    this.groupRoomId,
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
  final String? groupRoomId;

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
    'groupRoomId': groupRoomId,
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
      groupRoomId:
          json['groupRoomId'] is String &&
              RegExp(r'^[a-zA-Z0-9-]{1,80}$').hasMatch(json['groupRoomId'])
          ? json['groupRoomId'] as String
          : null,
    );
  }
}

class _DraftOperations {
  Future<void> tail = Future.value();
  int generation = 0;
}

class WorkoutDraftStore {
  WorkoutDraftStore(this.ownerId) : _generation = ++_nextGeneration;
  final String? ownerId;
  String? _verifiedText;
  static final Map<String?, _DraftOperations> _operations = {};
  _DraftOperations get _operationsForOwner =>
      _operations.putIfAbsent(_key, _DraftOperations.new);
  // Construction order matters: a disposed controller must not acquire a
  // newer lease merely because its first checkpoint reaches us late.
  static int _nextGeneration = 0;
  final int _generation;

  bool _claimWriter(_DraftOperations operations) {
    if (_generation < operations.generation) return false;
    operations.generation = _generation;
    return true;
  }

  String? get _key =>
      ownerId == null ? null : UserScope.keyFor('workout_draft', ownerId);

  Future<T> _serial<T>(Future<T> Function() operation) {
    final operations = _operationsForOwner;
    final result = operations.tail.then((_) => operation());
    operations.tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _preserveDamaged(
    SharedPreferences prefs,
    String key,
    String text,
  ) async {
    final backup = '${key}_damaged_${sha256.convert(utf8.encode(text))}';
    // setString updates the preferences cache before platform confirmation.
    // Always confirm this backup on disk before replacing damaged bytes.
    if (!await prefs.setString(backup, text)) {
      throw StateError(
        'Не удалось сохранить резервную копию черновика. Исходник не изменён.',
      );
    }
  }

  WorkoutDraft _decode(String text) => WorkoutDraft.fromJson(
    Map<String, dynamic>.from(jsonDecode(text) as Map),
    ownerId!,
  );

  Future<WorkoutDraft?> load() => _serial(() async {
    final key = _key;
    if (key == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString(key);
    if (text == null) return null;
    try {
      final draft = _decode(text);
      _verifiedText = text;
      return draft;
    } catch (_) {
      await _preserveDamaged(prefs, key, text);
      throw const FormatException(
        'Черновик повреждён. Резервная копия сохранена; можно начать новую поездку.',
      );
    }
  });

  Future<void> save(WorkoutDraft draft) {
    if (_key == null || draft.ownerId != ownerId) return Future.value();
    final operations = _operationsForOwner;
    if (!_claimWriter(operations)) return Future.value();
    final generation = _generation;
    return _serial(() async {
      if (generation != operations.generation) return;
      final key = _key;
      if (key == null || draft.ownerId != ownerId) return;
      final prefs = await SharedPreferences.getInstance();
      final previous = prefs.getString(key);
      if (previous != null && previous != _verifiedText) {
        try {
          _decode(previous);
        } catch (_) {
          await _preserveDamaged(prefs, key, previous);
        }
      }
      final encoded = jsonEncode(draft.toJson());
      if (!await prefs.setString(key, encoded)) {
        throw StateError('Не удалось сохранить черновик поездки');
      }
      _verifiedText = encoded;
    });
  }

  Future<void> delete() {
    final operations = _operationsForOwner;
    if (!_claimWriter(operations)) return Future.value();
    final generation = _generation;
    return _serial(() async {
      if (generation != operations.generation) return;
      final key = _key;
      if (key == null) return;
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.remove(key)) {
        throw StateError('Не удалось удалить черновик поездки');
      }
    });
  }
}
