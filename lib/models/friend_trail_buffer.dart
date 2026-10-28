import 'package:latlong2/latlong.dart';

import 'friend_profile.dart';

class FriendTrailPoint {
  const FriendTrailPoint(this.position, this.at);
  final LatLng position;
  final DateTime at;
}

class _FriendTrail {
  _FriendTrail(this.updatedAt, this.activity);
  DateTime updatedAt;
  final String? activity;
  final points = <FriendTrailPoint>[];
}

/// Only positions already received by this viewer. Never saved or uploaded.
class FriendTrailBuffer {
  static const lifetime = Duration(minutes: 2);
  static const freshness = Duration(seconds: 30);
  static const maxMeters = 200.0;
  static const maxPoints = 32;
  final _trails = <String, _FriendTrail>{};
  final _distance = const Distance();

  void clear() => _trails.clear();

  void sync(List<FriendProfile> friends, DateTime now) {
    final visible = friends.map((friend) => friend.id).toSet();
    _trails.removeWhere((id, _) => !visible.contains(id));
    for (final friend in friends) {
      final at = friend.liveUpdatedAt;
      final lat = friend.liveLatitude, lon = friend.liveLongitude;
      if (at == null ||
          lat == null ||
          lon == null ||
          !lat.isFinite ||
          !lon.isFinite ||
          lat.abs() > 90 ||
          lon.abs() > 180 ||
          now.difference(at) > freshness ||
          at.difference(now) > const Duration(seconds: 5)) {
        _trails.remove(friend.id);
        continue;
      }
      var trail = _trails[friend.id];
      if (trail != null && at.isBefore(trail.updatedAt)) continue;
      if (trail == null ||
          trail.activity != friend.liveActivity ||
          at.difference(trail.updatedAt) > freshness) {
        trail = _FriendTrail(at, friend.liveActivity);
        _trails[friend.id] = trail;
      }
      final point = LatLng(lat, lon);
      if (trail.points.isEmpty) {
        trail.points.add(FriendTrailPoint(point, at));
      } else if (at.isAfter(trail.updatedAt)) {
        final previous = trail.points.last;
        final meters = _distance.as(LengthUnit.Meter, previous.position, point);
        final seconds = at.difference(previous.at).inMilliseconds / 1000;
        // Break on teleports/GPS jumps rather than drawing a false connector.
        if (meters > maxMeters || (seconds > 0 && meters / seconds > 85)) {
          trail.points.clear();
          trail.points.add(FriendTrailPoint(point, at));
        } else if (meters >= 4 && !friend.livePaused) {
          trail.points.add(FriendTrailPoint(point, at));
        }
      }
      trail.updatedAt = at;
    }
    prune(now);
  }

  void prune(DateTime now) {
    _trails.removeWhere(
      (_, trail) => now.difference(trail.updatedAt) > freshness,
    );
    for (final trail in _trails.values) {
      trail.points.removeWhere((point) => now.difference(point.at) > lifetime);
      while (trail.points.length > maxPoints) {
        trail.points.removeAt(0);
      }
      var length = 0.0;
      for (var i = trail.points.length - 1; i > 0; i--) {
        length += _distance.as(
          LengthUnit.Meter,
          trail.points[i].position,
          trail.points[i - 1].position,
        );
        if (length > maxMeters) {
          trail.points.removeRange(0, i);
          break;
        }
      }
    }
  }

  List<FriendTrailPoint> pointsFor(String id) =>
      List.unmodifiable(_trails[id]?.points ?? const <FriendTrailPoint>[]);
}
