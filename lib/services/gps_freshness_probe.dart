import 'package:geolocator/geolocator.dart';

import '../models/gps_signal.dart';

/// Distance-filtered streams can be silent while stationary. A real one-shot
/// fix checks freshness without appending stationary jitter to the workout.
class GpsFreshnessProbe {
  GpsFreshnessProbe({
    required this.read,
    required this.current,
    required this.accept,
  });
  final Future<Position> Function() read;
  final GpsSignal Function() current;
  final void Function(Position) accept;
  DateTime? _lastAttempt;
  bool _busy = false, _disposed = false;
  Future<void> check(DateTime now, {bool enabled = true}) async {
    if (!enabled || _disposed || _busy) return;
    final signal = current();
    if (signal.updatedAt == null ||
        now.difference(signal.updatedAt!) < const Duration(seconds: 20)) {
      return;
    }
    if (_lastAttempt != null &&
        now.difference(_lastAttempt!) < const Duration(seconds: 20)) {
      return;
    }
    _busy = true;
    _lastAttempt = now;
    try {
      final fix = await read();
      if (_disposed ||
          !fix.latitude.isFinite ||
          !fix.longitude.isFinite ||
          fix.latitude.abs() > 90 ||
          fix.longitude.abs() > 180 ||
          fix.timestamp.isAfter(DateTime.now().add(const Duration(seconds: 5)))) {
        return;
      }
      final latest = current().updatedAt;
      if (latest == null || fix.timestamp.isAfter(latest)) accept(fix);
    } catch (_) {
      /* No new fix: the existing freshness deadline still applies. */
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _disposed = true;
  }
}
