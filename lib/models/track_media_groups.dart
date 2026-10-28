import 'package:latlong2/latlong.dart';

import 'dart:math' as math;

/// Nearby anchors at the current zoom share a marker. Selection remains by id.
List<List<T>> groupTrackMedia<T>(
  List<T> items,
  List<LatLng> points,
  int Function(T) index,
  double zoom,
) {
  final groups = <List<T>>[];
  const distance = Distance();
  for (final item in items) {
    final at = index(item);
    if (at < 0 || at >= points.length) continue;
    final threshold =
        (72 *
                156543.03 *
                math.cos(points[at].latitude * math.pi / 180) /
                math.pow(2, zoom.clamp(0, 22)))
            .clamp(2.0, 2000.0);
    final group = groups
        .where((g) => distance(points[index(g.first)], points[at]) < threshold)
        .firstOrNull;
    if (group == null) {
      groups.add([item]);
    } else {
      group.add(item);
    }
  }
  return groups;
}
