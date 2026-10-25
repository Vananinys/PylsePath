import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

/// Display interpolation only; recorded GPS points are never changed.
class SmoothMapPosition extends ValueNotifier<LatLng> {
  SmoothMapPosition(super.value);
  Timer? _timer;
  bool _hasFix = false;

  void update(LatLng target) {
    _timer?.cancel();
    if (!_hasFix ||
        const Distance().as(LengthUnit.Meter, value, target) > 250) {
      _hasFix = true;
      value = target;
      return;
    }
    final start = value;
    if (start == target) return;
    final clock = Stopwatch()..start();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      final t = (clock.elapsedMilliseconds / 900).clamp(0.0, 1.0);
      value = interpolate(start, target, t);
      if (t == 1) timer.cancel();
    });
  }

  static LatLng interpolate(LatLng start, LatLng end, double t) {
    final longitudeDelta = (end.longitude - start.longitude + 540) % 360 - 180;
    return LatLng(
      start.latitude + (end.latitude - start.latitude) * t,
      (start.longitude + longitudeDelta * t + 540) % 360 - 180,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
