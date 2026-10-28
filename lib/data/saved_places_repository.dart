import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_place.dart';
import 'user_scope.dart';

class SavedPlacesRepository {
  SavedPlacesRepository({String? owner, String? Function()? currentUser})
    : _currentUser = currentUser ?? UserScope.currentUserId,
      owner = owner ?? (currentUser ?? UserScope.currentUserId)();

  static const maxPlaces = 200;
  static final _queues = <String, Future<void>>{};
  @visibleForTesting
  static void resetQueuesForTesting() => _queues.clear();
  final String? owner;
  final String? Function() _currentUser;
  String get key => UserScope.keyFor('saved_places_v1', owner);
  bool get isCurrent => owner == _currentUser();

  void _checkOwner() {
    if (!isCurrent) {
      throw StateError('Аккаунт изменился. Откройте «Мои места» заново.');
    }
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = (_queues[key] ?? Future<void>.value()).then(
      (_) => operation(),
    );
    _queues[key] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<List<SavedPlace>> _read() async {
    _checkOwner();
    final prefs = await SharedPreferences.getInstance();
    _checkOwner();
    final text = prefs.getString(key);
    if (text == null) return [];
    if (text.length > 200000) {
      throw const FormatException('Слишком большой список мест');
    }
    final envelope = jsonDecode(text);
    if (envelope is! Map ||
        envelope['version'] != 1 ||
        envelope['places'] is! List) {
      throw const FormatException(
        'Не удалось прочитать места. Исходные данные не изменены.',
      );
    }
    final rows = envelope['places'] as List;
    if (rows.length > maxPlaces) {
      throw const FormatException('Превышен лимит мест');
    }
    final places = rows
        .map(
          (row) => SavedPlace.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
    if (places.map((p) => p.id).toSet().length != places.length) {
      throw const FormatException('Повторяются идентификаторы мест');
    }
    return places;
  }

  Future<void> _write(List<SavedPlace> places) async {
    _checkOwner();
    final prefs = await SharedPreferences.getInstance();
    _checkOwner();
    if (!await prefs.setString(
      key,
      jsonEncode({
        'version': 1,
        'places': places.map((p) => p.toJson()).toList(),
      }),
    )) {
      throw StateError('Не удалось сохранить места на телефоне');
    }
  }

  Future<List<SavedPlace>> load() =>
      _serial(() async => List.unmodifiable(await _read()));

  Future<void> save(SavedPlace place) => _serial(() async {
    final places = await _read();
    final index = places.indexWhere((p) => p.id == place.id);
    if (index < 0) {
      if (places.length >= maxPlaces) {
        throw StateError('Можно сохранить не более $maxPlaces мест');
      }
      places.add(place);
    } else {
      places[index] = place;
    }
    await _write(places);
  });

  Future<void> remove(String id) => _serial(() async {
    final places = await _read();
    places.removeWhere((p) => p.id == id);
    await _write(places);
  });
}
