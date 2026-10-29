import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Conservative route envelope, not a claim of routable offline road data.
class OfflineRouteTiles {
  OfflineRouteTiles(List<LatLng> points) {
    if (points.length < 2 ||
        points.any(
          (p) =>
              !p.latitude.isFinite ||
              !p.longitude.isFinite ||
              p.latitude.abs() > 85 ||
              p.longitude.abs() > 180,
        )) {
      throw const FormatException(
        'Для подготовки нужен корректный маршрут между широтами −85° и 85°.',
      );
    }
    south = points.map((p) => p.latitude).reduce(math.min) - .003;
    north = points.map((p) => p.latitude).reduce(math.max) + .003;
    final lonPadding =
        .003 /
        math.cos((south + north) / 2 * math.pi / 180).abs().clamp(.08, 1);
    west = (points.map((p) => p.longitude).reduce(math.min) - lonPadding).clamp(
      -180,
      180,
    );
    east = (points.map((p) => p.longitude).reduce(math.max) + lonPadding).clamp(
      -180,
      180,
    );
    if (east - west > 180)
      throw const FormatException(
        'Маршрут через линию смены дат нужно разделить на области.',
      );
    if (tiles.length > limit)
      throw const FormatException(
        'Область слишком большая: разделите маршрут на части. Лимит — 8000 тайлов.',
      );
  }
  static const limit = 8000;
  late final double south, north, west, east;
  int _x(double lon, int z) =>
      ((lon + 180) / 360 * (1 << z)).floor().clamp(0, (1 << z) - 1);
  int _y(double lat, int z) {
    final r = lat.clamp(-85.05112878, 85.05112878) * math.pi / 180;
    return ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) /
            2 *
            (1 << z))
        .floor()
        .clamp(0, (1 << z) - 1);
  }

  List<({int x, int y, int z})> get tiles {
    final result = <({int x, int y, int z})>[];
    for (var z = 13; z <= 16; z++) {
      for (var x = _x(west, z); x <= _x(east, z); x++) {
        for (var y = _y(north, z); y <= _y(south, z); y++) {
          result.add((x: x, y: y, z: z));
          if (result.length > limit) return result;
        }
      }
    }
    return result;
  }
}
