import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/ride_media.dart';
import 'user_scope.dart';

class RideMediaRepository {
  RideMediaRepository(
    this.rideId, {
    String? owner,
    String? Function()? currentOwner,
  }) : owner = owner ?? UserScope.currentUserId(),
       _currentOwner = currentOwner ?? UserScope.currentUserId {
    if (!RegExp(r'^[a-zA-Z0-9-]{1,80}$').hasMatch(rideId)) {
      throw const FormatException('Некорректная поездка');
    }
  }
  final String rideId;
  final String? owner;
  final String? Function() _currentOwner;
  static final Map<String, Future<void>> _queues = {};
  String get _key => UserScope.keyFor('ride_media_v1_$rideId', owner);
  bool get isCurrent => _currentOwner() == owner;
  void _check() {
    if (!isCurrent) throw StateError('Аккаунт изменился');
  }

  Future<List<RideMedia>> load() async {
    _check();
    final prefs = await SharedPreferences.getInstance();
    _check();
    final text = prefs.getString(_key);
    if (text == null) return [];
    if (text.length > 200000) {
      throw const FormatException('Слишком большой список материалов');
    }
    final raw = jsonDecode(text);
    if (raw is! Map ||
        raw['version'] != 1 ||
        raw['items'] is! List ||
        (raw['items'] as List).length > 20) {
      throw const FormatException('Повреждён список материалов');
    }
    final rows = (raw['items'] as List).map(RideMedia.fromJson).toList();
    if (rows.map((e) => e.id).toSet().length != rows.length) {
      throw const FormatException('Повторяющиеся материалы');
    }
    return List.unmodifiable(rows);
  }

  Future<void> _change(List<RideMedia> Function(List<RideMedia>) edit) {
    final result = (_queues[_key] ?? Future.value())
        .catchError((Object _) {})
        .then((_) async {
          final rows = edit(List.of(await load()));
          _check();
          if (rows.length > 20 ||
              rows.map((r) => r.id).toSet().length != rows.length) {
            throw StateError('Можно сохранить до 20 материалов на поездку');
          }
          for (final row in rows) {
            RideMedia.fromJson(row.toJson());
          }
          final prefs = await SharedPreferences.getInstance();
          _check();
          if (!await prefs.setString(
            _key,
            jsonEncode({
              'version': 1,
              'items': rows.map((r) => r.toJson()).toList(),
            }),
          )) {
            throw StateError('Не удалось сохранить материалы');
          }
        });
    _queues[_key] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> add(List<RideMedia> items, {required int pointCount}) =>
      _change((rows) {
        if (items.any((item) => item.pointIndex >= pointCount)) {
          throw StateError('Точка вне трека');
        }
        return [...rows, ...items];
      });
  Future<void> update(RideMedia item, {required int pointCount}) =>
      _change((rows) {
        final index = rows.indexWhere((r) => r.id == item.id);
        if (index < 0 || item.pointIndex >= pointCount) {
          throw StateError('Материал или точка недоступны');
        }
        rows[index] = item;
        return rows;
      });
  Future<void> remove(String id) =>
      _change((rows) => rows.where((r) => r.id != id).toList());
}
