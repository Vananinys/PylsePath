import 'package:latlong2/latlong.dart';

/// Presentation only: never extrapolates or changes the received GPS history.
class FriendMotion {
  FriendMotion(this.target, this.at) : origin = target;
  LatLng origin, target;
  DateTime at;
  DateTime? started;
  Duration duration = Duration.zero;
  double? heading;
  DateTime? lastMovementAt;
  double? _previousHeading;
  static const distance = Distance();

  LatLng position(DateTime now) {
    if (started == null || duration == Duration.zero) return target;
    final t =
        (now.difference(started!).inMicroseconds / duration.inMicroseconds)
            .clamp(0.0, 1.0);
    // Shortest longitude arc, including the international date line.
    final delta = (target.longitude - origin.longitude + 540) % 360 - 180;
    return LatLng(
      origin.latitude + (target.latitude - origin.latitude) * t,
      (origin.longitude + delta * t + 540) % 360 - 180,
    );
  }

  bool animating(DateTime now) =>
      started != null && now.difference(started!) < duration;

  double? direction(DateTime now) {
    if (heading == null ||
        lastMovementAt == null ||
        now.difference(lastMovementAt!) > const Duration(seconds: 15)) {
      return null;
    }
    if (_previousHeading == null ||
        started == null ||
        duration == Duration.zero) {
      return heading;
    }
    final t =
        (now.difference(started!).inMicroseconds / duration.inMicroseconds)
            .clamp(0.0, 1.0);
    final delta = (heading! - _previousHeading! + 540) % 360 - 180;
    return (_previousHeading! + delta * t + 360) % 360;
  }

  void update(
    LatLng next,
    DateTime timestamp,
    DateTime now, {
    bool paused = false,
  }) {
    if (!timestamp.isAfter(at)) return;
    final meters = distance.as(LengthUnit.Meter, target, next);
    final gap = timestamp.difference(at);
    final seconds = gap.inMilliseconds / 1000;
    final continuous =
        gap <= const Duration(minutes: 2) &&
        meters <= 200 &&
        seconds > 0 &&
        meters / seconds <= 85;
    origin = position(now);
    _previousHeading = direction(now);
    if (continuous && meters >= 4 && !paused) {
      heading = distance.bearing(target, next);
      lastMovementAt = now;
    } else if (!continuous || paused) {
      heading = null;
    }
    target = next;
    at = timestamp;
    started = now;
    duration = continuous
        ? Duration(milliseconds: gap.inMilliseconds.clamp(350, 1800))
        : Duration.zero;
  }
}
