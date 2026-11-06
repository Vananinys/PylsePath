import 'dart:ui';
import 'dart:collection';

import 'package:latlong2/latlong.dart';

/// Reuses fixed-zoom projections without mutating a previous painter's geometry.
class TrailProjectionCache {
  List<List<LatLng>>? _input;
  List<List<LatLng>> _source = const [];
  List<List<Offset>> _world = const [];

  void clear() {
    _input = null;
    _source = const [];
    _world = const [];
  }

  List<List<Offset>> update(
    List<List<LatLng>> segments,
    Offset Function(LatLng) project, {
    bool immutable = false,
  }) {
    if (immutable && identical(_input, segments)) return _world;
    final next = <List<Offset>>[];
    var changed = segments.length != _world.length;
    for (var i = 0; i < segments.length; i++) {
      final points = segments[i];
      final previous = i < _source.length ? _source[i] : const <LatLng>[];
      var prefix = 0;
      if (identical(points, previous) && immutable) {
        prefix = points.length;
      } else {
        while (prefix < previous.length &&
            prefix < points.length &&
            (identical(previous[prefix], points[prefix]) ||
                previous[prefix] == points[prefix])) {
          prefix++;
        }
      }
      if (i < _world.length &&
          prefix == points.length &&
          prefix == previous.length) {
        next.add(_world[i]);
      } else {
        changed = true;
        next.add(
          UnmodifiableListView<Offset>([
            if (i < _world.length) ..._world[i].take(prefix),
            for (var j = prefix; j < points.length; j++) project(points[j]),
          ]),
        );
      }
    }
    _input = segments;
    _source = immutable
        ? segments
        : [for (final s in segments) List<LatLng>.of(s)];
    if (changed) _world = List<List<Offset>>.unmodifiable(next);
    return _world;
  }
}
