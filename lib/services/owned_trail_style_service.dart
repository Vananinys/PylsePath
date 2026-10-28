import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/user_scope.dart';
import '../models/live_trail_style.dart';

class OwnedTrailStyleService extends ChangeNotifier {
  OwnedTrailStyleService({
    String? Function()? currentOwner,
    Future<Map<String, dynamic>?> Function(String)? readRemote,
    Future<void> Function(String, Map<String, Object>)? writeRemote,
  }) : _getOwner = currentOwner ?? UserScope.currentUserId,
       _readOverride = readRemote,
       _writeOverride = writeRemote;
  final String? Function() _getOwner;
  final Future<Map<String, dynamic>?> Function(String)? _readOverride;
  final Future<void> Function(String, Map<String, Object>)? _writeOverride;
  static final instance = OwnedTrailStyleService();
  String? _owner;
  LiveTrailStyle _style = const LiveTrailStyle();
  bool _pending = false;
  String? _loadedOwner;
  Future<void> _tail = Future.value();
  StreamSubscription<AuthState>? _auth;
  Timer? _retry;
  String? get _current => _getOwner();
  Future<Map<String, dynamic>?> _read(String owner) async =>
      _readOverride != null
      ? await _readOverride(owner)
      : await Supabase.instance.client
            .from('profile_trail_styles')
            .select()
            .eq('user_id', owner)
            .maybeSingle();
  Future<void> _write(String owner, Map<String, Object> row) async {
    if (_writeOverride != null) {
      await _writeOverride(owner, row);
      return;
    }
    await Supabase.instance.client.from('profile_trail_styles').upsert({
      'user_id': owner,
      ...row,
    }, onConflict: 'user_id');
  }

  LiveTrailStyle get style =>
      _owner == _current ? _style : const LiveTrailStyle();
  bool get pending => _owner == _current && _pending;
  String _key(String owner) => UserScope.keyFor('owned_trail_style_v1', owner);

  void start() {
    if (_auth != null) return;
    try {
      _auth = Supabase.instance.client.auth.onAuthStateChange.listen((_) {
        unawaited(load(refresh: true).catchError((Object _) {}));
      });
      _retry = Timer.periodic(const Duration(seconds: 30), (_) {
        if (pending) unawaited(load(refresh: true).catchError((Object _) {}));
      });
      unawaited(load().catchError((Object _) {}));
    } catch (_) {
      /* Startup can continue without a configured backend. */
    }
  }

  Future<void> _serialize(Future<void> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> load({bool refresh = false}) {
    final owner = _current;
    return _serialize(() async {
      if (owner != _current) return;
      if (owner == null) {
        _owner = null;
        _loadedOwner = null;
        _pending = false;
        _style = const LiveTrailStyle();
        notifyListeners();
        return;
      }
      if (!refresh && _loadedOwner == owner) return;
      _owner = owner;
      _style = const LiveTrailStyle();
      _pending = false;
      final prefs = await SharedPreferences.getInstance();
      if (owner != _current) return;
      final raw = prefs.get(_key(owner));
      if (raw is String) {
        try {
          final row = jsonDecode(raw) as Map<String, dynamic>;
          _style = LiveTrailStyle.fromRow(row);
          _pending = row['pending'] == true;
        } catch (_) {
          /* Keep unreadable originals; don't write on read. */
        }
      }
      _loadedOwner = owner;
      notifyListeners();
      if (_pending) {
        await _sync(owner, prefs);
        return;
      }
      try {
        final row = await _read(owner).timeout(const Duration(seconds: 10));
        if (owner != _current || row == null) return;
        _style = LiveTrailStyle.fromRow(row);
        await prefs.setString(
          _key(owner),
          jsonEncode({..._style.toRow(), 'pending': false}),
        );
        if (owner == _current) notifyListeners();
      } catch (_) {
        /* Cached owner appearance remains usable offline. */
      }
    });
  }

  Future<void> save(LiveTrailStyle next) {
    next = LiveTrailStyle.fromRow(next.toRow());
    final owner = _current;
    if (owner == null) return Future.error(StateError('Войдите в аккаунт'));
    return _serialize(() async {
      if (owner != _current) throw StateError('Аккаунт изменился');
      final prefs = await SharedPreferences.getInstance();
      if (owner != _current) throw StateError('Аккаунт изменился');
      if (!await prefs.setString(
        _key(owner),
        jsonEncode({...next.toRow(), 'pending': true}),
      )) {
        await prefs.reload();
        throw StateError('Не удалось сохранить оформление');
      }
      if (owner != _current) return;
      _owner = owner;
      _loadedOwner = owner;
      _style = next;
      _pending = true;
      notifyListeners();
      await _sync(owner, prefs);
    });
  }

  Future<void> _sync(String owner, SharedPreferences prefs) async {
    if (owner != _current || _owner != owner || !_pending) return;
    try {
      await _write(owner, _style.toRow()).timeout(const Duration(seconds: 10));
      if (owner != _current) return;
      final saved = await prefs.setString(
        _key(owner),
        jsonEncode({..._style.toRow(), 'pending': false}),
      );
      if (owner != _current) return;
      if (saved) _pending = false;
      notifyListeners();
    } catch (_) {
      /* Retry the account-scoped choice on reconnect/timer. */
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    unawaited(_auth?.cancel());
    super.dispose();
  }
}
