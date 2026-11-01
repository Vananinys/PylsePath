import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Generates input observations, never navigation results. Only used after
/// laboratory authorization; it does not change Android's system location.
class LaboratoryMotionSource extends ChangeNotifier {
  LaboratoryMotionSource(this.point, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final _positions = StreamController<Position>.broadcast(sync: true);
  Stream<Position> get positions => _positions.stream;
  LatLng point;
  double speedKmh = 15, heading = 0, altitude = 100, accuracy = 5;
  bool moving = false, gpsAvailable = true;
  List<LatLng> _targets = [];
  bool get followingRoute => _targets.isNotEmpty;
  void followRoute(List<LatLng> route) {
    if (route.length < 2)
      throw StateError('Сначала постройте или откройте маршрут');
    var closest = 0, best = double.infinity;
    for (var i = 0; i < route.length; i++) {
      final d = const Distance()(point, route[i]);
      if (d < best) {
        best = d;
        closest = i;
      }
    }
    _targets = List.of(route.skip(closest));
    moving = true;
    emit();
  }

  void steer(double bearing) {
    _targets = [];
    heading = bearing;
    emit();
  }

  Timer? _timer;
  DateTime? _lastTick;
  void start() {
    _lastTick = _now();
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => tick());
    emit();
  }

  void tick() {
    final at = _now();
    final elapsed = _lastTick == null
        ? 0.0
        : at.difference(_lastTick!).inMilliseconds / 1000;
    _lastTick = at;
    // Do not jump across a suspended process interval.
    if (moving && elapsed > 0 && elapsed <= 3) {
      var remaining = speedKmh / 3.6 * elapsed;
      final wasFollowing = followingRoute;
      while (_targets.isNotEmpty) {
        final target = _targets.first;
        final distance = const Distance()(point, target);
        if (distance <= remaining) {
          remaining -= distance;
          point = target;
          _targets.removeAt(0);
        } else {
          heading = (const Distance().bearing(point, target) + 360) % 360;
          point = const Distance().offset(point, remaining, heading);
          remaining = 0;
          break;
        }
      }
      if (!wasFollowing)
        point = const Distance().offset(point, remaining, heading);
      if (wasFollowing && _targets.isEmpty) moving = false;
    }
    emit();
  }

  void emit() {
    if (gpsAvailable && !_positions.isClosed) {
      _positions.add(
        Position(
          latitude: point.latitude,
          longitude: point.longitude,
          timestamp: _now(),
          accuracy: accuracy,
          altitude: altitude,
          altitudeAccuracy: 2,
          heading: heading,
          headingAccuracy: 1,
          speed: moving ? speedKmh / 3.6 : 0,
          speedAccuracy: .1,
          isMocked: true,
        ),
      );
    }
    notifyListeners();
  }

  void suspend() {
    moving = false;
    _timer?.cancel();
    _timer = null;
  }

  void stopMovement() {
    moving = false;
    emit();
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_positions.close());
    super.dispose();
  }
}
