import 'dart:math' as math;

/// GPS-derived deceleration exposure, NOT measured brake wear or brake work.
/// Energy is kinetic energy lost during confirmed slowing events; air, slope
/// and rolling resistance also contribute. No front/rear split is assumed.
class BrakeLoad {
  const BrakeLoad({
    this.slowdowns = 0,
    this.accelerations = 0,
    this.kineticKj = 0,
    this.coveredSeconds = 0,
    this.slowingSeconds = 0,
    this.systemMassKg,
    this.massAssumed = false,
  });
  final int slowdowns, accelerations;
  final double kineticKj, coveredSeconds, slowingSeconds;
  final double? systemMassKg;
  final bool massAssumed;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'slowdowns': slowdowns,
    'accelerations': accelerations,
    'kinetic_kj': kineticKj,
    'covered_seconds': coveredSeconds,
    'slowing_seconds': slowingSeconds,
    'mass_kg': systemMassKg,
    'mass_assumed': massAssumed,
  };
  static BrakeLoad? fromJson(dynamic value) {
    if (value is! Map || value['version'] != 1) return null;
    bool valid(String key, double max) =>
        value[key] is num &&
        (value[key] as num).isFinite &&
        value[key] >= 0 &&
        value[key] <= max;
    if (!valid('slowdowns', 100000) ||
        !valid('accelerations', 100000) ||
        !valid('kinetic_kj', 1e7) ||
        !valid('covered_seconds', 1e7) ||
        !valid('slowing_seconds', 1e7) ||
        value['slowing_seconds'] > value['covered_seconds']) {
      return null;
    }
    final mass = value['mass_kg'];
    if (mass != null &&
        (mass is! num || !mass.isFinite || mass < 20 || mass > 450)) {
      return null;
    }
    return BrakeLoad(
      slowdowns: (value['slowdowns'] as num).toInt(),
      accelerations: (value['accelerations'] as num).toInt(),
      kineticKj: (value['kinetic_kj'] as num).toDouble(),
      coveredSeconds: (value['covered_seconds'] as num).toDouble(),
      slowingSeconds: (value['slowing_seconds'] as num).toDouble(),
      systemMassKg: (mass as num?)?.toDouble(),
      massAssumed: value['mass_assumed'] == true,
    );
  }
}

class BrakeLoadRecorder {
  BrakeLoadRecorder({
    double? systemMassKg,
    bool massAssumed = false,
    BrakeLoad? restored,
  }) : _total =
           restored ??
           BrakeLoad(systemMassKg: systemMassKg, massAssumed: massAssumed);
  BrakeLoad _total;
  BrakeLoad get snapshot => _total;
  DateTime? _lastAt;
  double? _lastSpeed;
  final _window = <double>[];
  int _direction = 0, _intervals = 0;
  double _change = 0, _seconds = 0, _energy = 0;
  bool _confirmed = false;

  /// Pauses, lost fixes and process recovery must not connect two segments.
  void breakSegment() {
    _lastAt = null;
    _lastSpeed = null;
    _window.clear();
    _resetEvent();
  }

  void _resetEvent() {
    _direction = 0;
    _intervals = 0;
    _change = _seconds = _energy = 0;
    _confirmed = false;
  }

  void add({
    required DateTime at,
    required double speedMps,
    required double accuracyMeters,
    required double speedAccuracyMps,
  }) {
    if (_lastAt != null && !at.isAfter(_lastAt!)) return;
    if (!speedMps.isFinite ||
        speedMps < 0 ||
        speedMps > 35 ||
        !accuracyMeters.isFinite ||
        accuracyMeters < 0 ||
        accuracyMeters > 15 ||
        !speedAccuracyMps.isFinite ||
        speedAccuracyMps < 0 ||
        speedAccuracyMps > 1) {
      breakSegment();
      return;
    }
    final dt = _lastAt == null
        ? 0.0
        : at.difference(_lastAt!).inMilliseconds / 1000;
    if (dt > 0 && dt < .4) return;
    if (dt > 3) breakSegment();
    _window.add(speedMps);
    if (_window.length > 3) _window.removeAt(0);
    final sorted = [..._window]..sort();
    final speed = sorted[sorted.length ~/ 2];
    final previous = _lastSpeed;
    _lastAt = at;
    _lastSpeed = speed;
    if (previous == null || _window.length < 3 || dt <= 0 || dt > 3) return;
    final acceleration = (speed - previous) / dt;
    // Reject implausible jumps instead of counting them as hard braking.
    if (acceleration.abs() > 6) {
      breakSegment();
      return;
    }
    _total = BrakeLoad(
      slowdowns: _total.slowdowns,
      accelerations: _total.accelerations,
      kineticKj: _total.kineticKj,
      coveredSeconds: _total.coveredSeconds + dt,
      slowingSeconds: _total.slowingSeconds,
      systemMassKg: _total.systemMassKg,
      massAssumed: _total.massAssumed,
    );
    final direction = acceleration < -.45 && previous > 2
        ? -1
        : acceleration > .45 && speed > 2
        ? 1
        : 0;
    if (direction == 0 || direction != _direction) _resetEvent();
    if (direction == 0) return;
    _direction = direction;
    _intervals++;
    _change += (speed - previous).abs();
    _seconds += dt;
    final loss = direction < 0 && _total.systemMassKg != null
        ? math.max(
            0.0,
            .5 *
                _total.systemMassKg! *
                (previous * previous - speed * speed) /
                1000,
          )
        : 0.0;
    _energy += loss;
    // Median filter + two sustained intervals + >= 5.4 km/h total change.
    if (!_confirmed && (_intervals < 2 || _change < 1.5)) return;
    final newEvent = !_confirmed;
    _total = BrakeLoad(
      slowdowns: _total.slowdowns + (newEvent && direction < 0 ? 1 : 0),
      accelerations: _total.accelerations + (newEvent && direction > 0 ? 1 : 0),
      kineticKj: _total.kineticKj + (newEvent ? _energy : loss),
      coveredSeconds: _total.coveredSeconds,
      slowingSeconds:
          _total.slowingSeconds +
          (direction < 0 ? (newEvent ? _seconds : dt) : 0),
      systemMassKg: _total.systemMassKg,
      massAssumed: _total.massAssumed,
    );
    _confirmed = true;
  }
}

class BrakeInspection {
  const BrakeInspection({
    required this.at,
    required this.measuredMm,
    required this.minimumMm,
    required this.newMm,
    required this.basis,
  });
  final DateTime at;
  final double measuredMm, minimumMm, newMm;
  final String basis;
  bool get limitReached => measuredMm <= minimumMm;
  double get consumedFraction =>
      ((newMm - measuredMm) / (newMm - minimumMm)).clamp(0.0, 1.0);
  Map<String, dynamic> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'action': 'Замер',
    'measured_mm': measuredMm,
    'minimum_mm': minimumMm,
    'new_mm': newMm,
    'basis': basis,
  };
  static BrakeInspection? fromJson(Map value) {
    final at = DateTime.tryParse('${value['at']}');
    final current = value['measured_mm'],
        min = value['minimum_mm'],
        initial = value['new_mm'];
    if (at == null ||
        [
          current,
          min,
          initial,
        ].any((v) => v is! num || !v.isFinite || v <= 0 || v > 30) ||
        initial <= min ||
        current > initial ||
        ![
          'friction',
          'with_plate',
          'rotor',
          'rim_pad',
        ].contains(value['basis'])) {
      return null;
    }
    return BrakeInspection(
      at: at,
      measuredMm: (current as num).toDouble(),
      minimumMm: (min as num).toDouble(),
      newMm: (initial as num).toDouble(),
      basis: value['basis'] as String,
    );
  }
}
