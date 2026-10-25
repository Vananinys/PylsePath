import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../data/user_scope.dart';
import 'notification_permission_service.dart';

class BackgroundLocationPlatform {
  static const channel = MethodChannel('pulsepath/background_location');
  bool get supported => !kIsWeb && Platform.isAndroid;
  Future<Map<dynamic, dynamic>> invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async =>
      await channel.invokeMapMethod<dynamic, dynamic>(method, arguments) ?? {};
  Future<bool> requestPermissions() async {
    if (!(await Permission.locationWhenInUse.request()).isGranted) return false;
    final status = await invoke('status');
    if (status['backgroundPermission'] != true) {
      await Permission.locationAlways.request();
    }
    final checked = await invoke('status');
    if (checked['precisePermission'] != true ||
        checked['backgroundPermission'] != true) {
      return false;
    }
    return NotificationPermissionService.request();
  }
}

class BackgroundLocationRepository {
  Future<Map<String, dynamic>> issue(String deviceId) async {
    final dynamic result;
    try {
      result = await Supabase.instance.client.rpc(
        'pulsepath_issue_location_token',
        params: {'p_device_id': deviceId},
      );
    } on PostgrestException catch (error) {
      if (error.code == 'PGRST202' || error.code == '42883') {
        throw const BackgroundLocationSetupException();
      }
      rethrow;
    }
    return Map<String, dynamic>.from(result as Map);
  }

  Future<void> revoke(String token) async {
    await Supabase.instance.client.rpc(
      'pulsepath_stop_background_location',
      params: {'p_token': token},
    );
  }
}

class BackgroundLocationSetupException implements Exception {
  const BackgroundLocationSetupException();
}

/// The native service owns collection. Flutter never stays alive just to send coordinates.
class BackgroundLocationService extends ChangeNotifier {
  static final instance = BackgroundLocationService._(
    BackgroundLocationPlatform(),
    BackgroundLocationRepository(),
    UserScope.currentUserId,
  );
  BackgroundLocationService._(
    this._platform,
    this._repository,
    this._ownerResolver,
  );
  @visibleForTesting
  factory BackgroundLocationService.forTesting({
    required BackgroundLocationPlatform platform,
    required BackgroundLocationRepository repository,
    required String? Function() owner,
  }) => BackgroundLocationService._(platform, repository, owner);

  final BackgroundLocationPlatform _platform;
  final BackgroundLocationRepository _repository;
  final String? Function() _ownerResolver;
  Future<void> _queue = Future.value();
  bool _sharingAllowed = true;
  bool ready = false;
  bool busy = false;
  bool enabled = false;
  bool running = false;
  DateTime? lastPublishedAt;
  String? notice;
  bool get supported => _platform.supported;

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.catchError((Object error) {
      debugPrint('[BackgroundLocation] ${error.runtimeType}');
    });
    return next;
  }

  void _apply(Map<dynamic, dynamic> state) {
    enabled = state['enabled'] == true && state['owner'] == _ownerResolver();
    running = enabled && state['running'] == true;
    final stamp = (state['lastPublishedAt'] as num?)?.toInt() ?? 0;
    lastPublishedAt = enabled && stamp > 0
        ? DateTime.fromMillisecondsSinceEpoch(stamp)
        : null;
    final message = state['notice'] as String? ?? '';
    notice = message.isEmpty ? null : message;
    if (enabled &&
        (state['precisePermission'] != true ||
            state['backgroundPermission'] != true)) {
      running = false;
      notice = 'Для фонового режима нужны точное местоположение и «Разрешить всегда» в настройках телефона.';
    } else if (enabled && state['locationEnabled'] != true) {
      running = false;
      notice = 'Включите геопозицию в системных настройках телефона.';
    }
    if (enabled && !running && notice == null) {
      notice =
          state['precisePermission'] == true &&
              state['backgroundPermission'] == true
          ? 'Запускаем фоновое обновление…'
          : 'Откройте настройки доступа к геопозиции: нужны точное местоположение и «Разрешить всегда».';
    }
  }

  Future<void> bindToUser(String? owner) => _enqueue(() async {
    if (!supported) return;
    try {
      final state = await _platform.invoke('status');
      final nativeOwner = state['owner'] as String?;
      if (nativeOwner != null &&
          nativeOwner.isNotEmpty &&
          nativeOwner != owner) {
        _apply(await _platform.invoke('stop', {'owner': nativeOwner}));
      }
    } catch (_) {
      /* A missing platform in a test must not break auth routing. */
    }
  });

  void setSharingAllowed(bool value) {
    _sharingAllowed = value;
    if (!value) unawaited(setEnabled(false));
  }

  Future<void> restore({required bool shareAllowed}) {
    _sharingAllowed = shareAllowed;
    final owner = _ownerResolver();
    return _enqueue(() async {
      if (!supported) {
        ready = true;
        return;
      }
      try {
        var state = await _platform.invoke('status');
        final nativeOwner = state['owner'] as String? ?? '';
        if (owner == null || nativeOwner != owner || !_sharingAllowed) {
          if (nativeOwner.isNotEmpty && state['enabled'] == true) {
            state = await _platform.invoke('stop', {'owner': nativeOwner});
          }
          _apply(state);
          return;
        }
        _apply(state);
        if (!enabled ||
            state['precisePermission'] != true ||
            state['backgroundPermission'] != true ||
            state['locationEnabled'] != true ||
            state['servicesAvailable'] != true) {
          return;
        }
        final expires = (state['expiresAt'] as num?)?.toInt() ?? 0;
        if (expires <
            DateTime.now()
                .add(const Duration(days: 7))
                .millisecondsSinceEpoch) {
          await _start(owner, renew: true);
        } else {
          if (_ownerResolver() != owner || !_sharingAllowed) return;
          _apply(await _platform.invoke('start', {'owner': owner}));
        }
      } catch (error) {
        _report(error);
      } finally {
        ready = true;
        notifyListeners();
      }
    });
  }

  Future<void> refreshStatus() => _enqueue(() async {
    if (!supported) {
      ready = true;
      return;
    }
    try {
      _apply(await _platform.invoke('status'));
    } catch (error) {
      _report(error);
    } finally {
      ready = true;
      notifyListeners();
    }
  });

  Future<String> _deviceId() async {
    // Production identity lives in Android noBackupFilesDir and cannot clone via phone backups.
    final native = await _platform.invoke('status');
    final nativeId = native['deviceId'];
    if (nativeId is String && nativeId.length >= 16) return nativeId;
    final prefs = await SharedPreferences.getInstance();
    const key = 'background_location_device_id';
    var id = prefs.getString(key);
    if (id == null) {
      final random = Random.secure();
      id = List.generate(
        24,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await prefs.setString(key, id);
    }
    return id;
  }

  Future<void> _start(String owner, {required bool renew}) async {
    final credential = await _repository.issue(await _deviceId());
    final token = credential['token'] as String;
    if (_ownerResolver() != owner || !_sharingAllowed) {
      try {
        await _repository.revoke(token);
      } catch (_) {}
      return;
    }
    try {
      final expiry = DateTime.parse(credential['expires_at'] as String)
          .millisecondsSinceEpoch;
      _apply(
        await _platform.invoke('start', {
          'owner': owner,
          'token': token,
          'expiresAt': expiry,
          'url': AppConfig.supabaseUrl,
          'apiKey': AppConfig.supabasePublishableKey,
        }),
      );
    } catch (error) {
      try {
        await _repository.revoke(token);
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> setEnabled(bool value) {
    final owner = _ownerResolver();
    return _enqueue(() async {
      if (!supported) return;
      busy = true;
      notice = null;
      notifyListeners();
      try {
        if (!value) {
          _apply(
            await _platform.invoke('stop', {if (owner != null) 'owner': owner}),
          );
          return;
        }
        if (owner == null || !_sharingAllowed) {
          notice = 'Войдите в аккаунт и включите трансляцию позиции друзьям.';
          return;
        }
        if (!await _platform.requestPermissions()) {
          notice = 'Для работы при закрытом приложении разрешите точную геопозицию «Всегда» и системные уведомления в настройках телефона.';
          return;
        }
        if (_ownerResolver() != owner || !_sharingAllowed) return;
        await _start(owner, renew: true);
      } catch (error) {
        _report(error);
      } finally {
        busy = false;
        ready = true;
        notifyListeners();
      }
    });
  }

  void _report(Object error) {
    debugPrint('[BackgroundLocation] ${error.runtimeType}');
    if (error is BackgroundLocationSetupException) {
      notice = 'Фоновое обновление местоположения станет доступно после обновления сервера.';
      return;
    }
    notice = 'Не удалось включить или обновить фоновую геолокацию. Проверьте интернет, геопозицию и разрешение «Всегда».';
  }
}
