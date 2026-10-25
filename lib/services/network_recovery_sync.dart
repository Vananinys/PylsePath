import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// OS connectivity events trigger retries; the timer is a foreground fallback.
/// Jobs own their durable queues and deduplicate in-flight requests.
class NetworkRecoverySync {
  NetworkRecoverySync({
    required this.onSync,
    Stream<bool>? changes,
    this.retryInterval = const Duration(seconds: 30),
  }) : _changes = changes;
  final void Function(bool restored) onSync;
  final Stream<bool>? _changes;
  final Duration retryInterval;
  StreamSubscription<bool>? _subscription;
  Timer? _timer;
  bool _foreground = true, _disposed = false;
  bool? _online;
  void start() {
    if (_timer != null || _disposed) return;
    final source =
        _changes ??
        (!kIsWeb && defaultTargetPlatform == TargetPlatform.android
            ? const EventChannel('pulsepath/network_status')
                  .receiveBroadcastStream()
                  .map((v) => v == true)
            : const Stream<bool>.empty());
    _subscription = source.listen(
      (online) {
        final restored = online && _online != true;
        _online = online;
        if (restored && _foreground && !_disposed) onSync(true);
      },
      onError: (Object error) {
        /* Timer also works on unsupported platforms. */
      },
    );
    _timer = Timer.periodic(retryInterval, (_) {
      if (_foreground && !_disposed && _online != false) onSync(false);
    });
  }

  void setForeground(bool foreground) {
    final resumed = foreground && !_foreground;
    _foreground = foreground;
    if (resumed && !_disposed) onSync(true);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_subscription?.cancel());
  }
}
