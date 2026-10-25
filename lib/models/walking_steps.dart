import 'dart:math' as math;

class StepWindow {
  const StepWindow({
    required this.start,
    this.end,
    this.recorded = 0,
    this.live = 0,
  });
  final int start;
  final int? end;
  final int recorded, live;
  int get steps => math.max(recorded, live);
  bool contains(int time) => time >= start && (end == null || time < end!);
  StepWindow closed(int time) => StepWindow(
    start: start,
    end: math.max(start, time),
    recorded: recorded,
    live: live,
  );
  Map<String, dynamic> toJson() => {
    'start': start,
    'end': end,
    'recorded': recorded,
    'live': live,
  };
}

/// Each source measures the same steps. Merge by maximum per active interval.
class WalkingSteps {
  const WalkingSteps({
    required this.device,
    required this.windows,
    required this.observedAt,
    this.stride = .7,
  });
  final String device;
  final List<StepWindow> windows;
  final int observedAt;
  final double stride;
  int get count => windows.fold(0, (sum, w) => sum + w.steps);
  double get distanceKm => count * stride / 1000;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'device': device,
    'observed_at': observedAt,
    'stride': stride,
    'windows': windows.map((w) => w.toJson()).toList(),
  };
  static WalkingSteps? fromJson(dynamic value, {bool restorePaused = false}) {
    if (value is! Map ||
        value['version'] != 1 ||
        value['device'] is! String ||
        value['observed_at'] is! int ||
        value['windows'] is! List)
      return null;
    final stamp = value['observed_at'] as int;
    final windows = <StepWindow>[];
    for (final raw in (value['windows'] as List).take(256)) {
      if (raw is! Map || raw['start'] is! int) return null;
      final start = raw['start'] as int, end = raw['end'];
      if (start < 0 ||
          start > stamp ||
          (end != null && (end is! int || end < start || end > stamp)) ||
          (windows.isNotEmpty &&
              (windows.last.end == null || start < windows.last.end!)))
        return null;
      int safe(dynamic n) => n is int && n >= 0 && n <= 500000 ? n : 0;
      windows.add(
        StepWindow(
          start: start,
          end: end == null && restorePaused ? stamp : end as int?,
          recorded: safe(raw['recorded']),
          live: safe(raw['live']),
        ),
      );
    }
    final stride = value['stride'];
    return WalkingSteps(
      device: value['device'] as String,
      windows: List.unmodifiable(windows),
      observedAt: stamp,
      stride: stride is num && stride.isFinite && stride >= .4 && stride <= 1.2
          ? stride.toDouble()
          : .7,
    );
  }
}
