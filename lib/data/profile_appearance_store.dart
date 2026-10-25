import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'user_scope.dart';

/// One atomic envelope owns the visible snapshot and the upload queue.
class ProfileAppearanceStore {
  ProfileAppearanceStore(this.owner, {String? Function()? currentUser})
    : _currentUser = currentUser ?? UserScope.currentUserId;
  final String owner;
  final String? Function() _currentUser;
  String get key => UserScope.keyFor('profile_appearance_v2', owner);
  bool get current => _currentUser() == owner;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<Map<String, dynamic>?> _read() async {
    if (!current) return null;
    final prefs = await SharedPreferences.getInstance();
    if (!current) return null;
    final raw = prefs.getString(key);
    if (raw != null) {
      try {
        return Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {
        await prefs.setString('${key}_damaged', raw);
      }
    }
    // Import the cache written by earlier app versions without a network read.
    final legacy = prefs.getString(
      UserScope.keyFor('progress_cache_v1_presentation', owner),
    );
    if (legacy == null) return null;
    try {
      final result = Map<String, dynamic>.from(jsonDecode(legacy) as Map);
      return {...result, 'revision': 0, 'pending': false};
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(Map<String, dynamic> value) async {
    if (!current) throw StateError('Account changed');
    final prefs = await SharedPreferences.getInstance();
    if (!current || !await prefs.setString(key, jsonEncode(value)))
      throw StateError('Не удалось сохранить оформление на телефоне');
  }

  Future<Map<String, dynamic>?> read() => _serial(_read);
  Future<Map<String, dynamic>> stage(
    Map<String, dynamic> snapshot, {
    String? newPhoto,
  }) => _serial(() async {
    final previous = await _read() ?? {};
    final photo = newPhoto ?? snapshot['localPhoto'];
    final style = Map<String, dynamic>.from(snapshot['style'] as Map);
    if (newPhoto == null &&
        photo != null &&
        photo == previous['localPhoto'] &&
        previous['photoNeedsUpload'] == false) {
      style['cover_photo_path'] =
          (previous['style'] as Map)['cover_photo_path'];
    }
    final needsUpload =
        newPhoto != null ||
        (photo != null &&
            photo == previous['localPhoto'] &&
            previous['photoNeedsUpload'] == true);
    final next = {
      ...snapshot,
      'style': style,
      'revision': (previous['revision'] as int? ?? 0) + 1,
      'pending': true,
      'localPhoto': photo,
      'photoNeedsUpload': needsUpload,
    };
    await _write(next);
    return next;
  });
  Future<bool> acceptRemote(
    Map<String, dynamic> snapshot,
    int expectedRevision,
  ) => _serial(() async {
    final previous = await _read() ?? {};
    if (previous['pending'] == true ||
        (previous['revision'] as int? ?? 0) != expectedRevision)
      return false;
    final samePhoto =
        (snapshot['style'] as Map?)?['cover_photo_path'] ==
        (previous['style'] as Map?)?['cover_photo_path'];
    await _write({
      ...snapshot,
      'revision': expectedRevision,
      'pending': false,
      if (samePhoto) 'localPhoto': previous['localPhoto'],
    });
    return true;
  });
  Future<bool> recordUpload(String localPhoto, String objectPath) =>
      _serial(() async {
        final previous = await _read();
        if (previous == null ||
            previous['localPhoto'] != localPhoto ||
            previous['photoNeedsUpload'] != true)
          return false;
        await _write({
          ...previous,
          'photoNeedsUpload': false,
          'style': {
            ...Map<String, dynamic>.from(previous['style'] as Map),
            'cover_photo_path': objectPath,
          },
        });
        return true;
      });
  Future<bool> acknowledge(int revision) => _serial(() async {
    final previous = await _read();
    if (previous == null || previous['revision'] != revision) return false;
    await _write({...previous, 'pending': false});
    return true;
  });
}
