import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'compass_service.dart';

/// Frame-by-frame circular damping shared by the marker and camera.
class SmoothMapHeading extends ValueNotifier<double> {
  SmoothMapHeading() : super(0);
  Timer? _timer;
  double _target = 0;
  bool _initialized = false;

  void update(double target) {
    if (!target.isFinite) return;
    _target = CompassService.normalize(target);
    if (!_initialized) {
      _initialized = true;
      value = _target;
      return;
    }
    if (_timer != null) return;
    final clock = Stopwatch()..start();
    var previous = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final elapsed = clock.elapsedMicroseconds;
      final dt = ((elapsed - previous) / 1000000).clamp(0.0, 0.1);
      previous = elapsed;
      value = step(value, _target, dt);
      if (CompassService.shortestDelta(value, _target).abs() < 0.05) {
        value = _target;
        _timer?.cancel();
        _timer = null;
      }
    });
  }

  static double step(double current, double target, double seconds) =>
      CompassService.normalize(
        current +
            CompassService.shortestDelta(current, target) *
                (1 - math.exp(-seconds / 0.14)),
      );

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
