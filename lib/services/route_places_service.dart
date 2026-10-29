import 'dart:math' as math;
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../utils/geo_utils.dart';

class RoutePlace {
  const RoutePlace(
    this.id,
    this.name,
    this.kind,
    this.point,
    this.alongMeters,
    this.detourMeters,
  );
  final String id, name, kind;
  final LatLng point;
  final double alongMeters, detourMeters;
}

class RoutePlacesService {
  RoutePlacesService({this.client});
  final http.Client? client;
  static const endpoint = 'https://overpass-api.de/api/interpreter';
  static String query(List<LatLng> points) {
    if (points.length < 2 ||
        points.length > 2000 ||
        points.any(
          (p) =>
              !p.latitude.isFinite ||
              !p.longitude.isFinite ||
              p.latitude.abs() > 90 ||
              p.longitude.abs() > 180,
        )) {
      throw const FormatException(
        'Для поиска нужен маршрут из 2–2000 корректных точек. Длинный трек разделите на части.',
      );
    }
    final line = points
        .map(
          (p) =>
              '${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)}',
        )
        .join(',');
    return '[out:json][timeout:12];(nwr[amenity~"^(drinking_water|cafe|restaurant|bicycle_repair_station|bench|shelter)\u0024"](around:500,$line);nwr[shop="bicycle"](around:500,$line);nwr[tourism="picnic_site"](around:500,$line););out center 500;';
  }

  Future<List<RoutePlace>> fetch(List<LatLng> points) async {
    final body = query(points);
    final response =
        await (client?.post(Uri.parse(endpoint), body: body) ??
                http.post(Uri.parse(endpoint), body: body))
            .timeout(const Duration(seconds: 18));
    if (response.statusCode != 200 || response.bodyBytes.length > 3000000)
      throw StateError('Источник мест сейчас недоступен. Повторите позже.');
    final data = jsonDecode(response.body);
    if (data is! Map || data['remark'] != null || data['elements'] is! List)
      throw StateError('Источник вернул неполный результат. Повторите позже.');
    return parse(data['elements'] as List, points);
  }

  static List<RoutePlace> parse(List elements, List<LatLng> route) {
    final result = <RoutePlace>[];
    final ids = <String>{};
    for (final raw in elements.take(500)) {
      if (raw is! Map || raw['tags'] is! Map) continue;
      final tags = raw['tags'] as Map;
      if (![
            'drinking_water',
            'cafe',
            'restaurant',
            'bicycle_repair_station',
            'bench',
            'shelter',
          ].contains(tags['amenity']) &&
          tags['shop'] != 'bicycle' &&
          tags['tourism'] != 'picnic_site')
        continue;
      if (tags['amenity'] == 'drinking_water' && tags['drinking_water'] == 'no')
        continue;
      if (tags['access'] == 'private' || tags['access'] == 'no') continue;
      final coord = raw['lat'] is num ? raw : raw['center'];
      if (coord is! Map || coord['lat'] is! num || coord['lon'] is! num)
        continue;
      final lat = (coord['lat'] as num).toDouble(),
          lon = (coord['lon'] as num).toDouble();
      if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180)
        continue;
      final point = LatLng(lat, lon);
      final kind = tags['amenity'] == 'drinking_water'
          ? 'Вода'
          : tags['shop'] == 'bicycle' ||
                tags['amenity'] == 'bicycle_repair_station'
          ? 'Велоремонт'
          : ['cafe', 'restaurant'].contains(tags['amenity'])
          ? 'Кафе'
          : 'Отдых';
      var best = double.infinity, along = 0.0, offset = 0.0;
      for (var i = 1; i < route.length; i++) {
        final a = route[i - 1],
            b = route[i],
            length = GeoUtils.distanceBetween(a, b);
        final d = GeoUtils.distanceToSegment(point, a, b);
        final dx =
                (b.longitude - a.longitude) *
                math.cos(point.latitude * math.pi / 180),
            dy = b.latitude - a.latitude;
        final px =
                (point.longitude - a.longitude) *
                math.cos(point.latitude * math.pi / 180),
            py = point.latitude - a.latitude;
        final t = dx * dx + dy * dy == 0
            ? 0.0
            : ((px * dx + py * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0);
        if (d < best) {
          best = d;
          along = offset + length * t;
        }
        offset += length;
      }
      final id = '${raw['type']}/${raw['id']}';
      if (best > 550 || !ids.add(id)) continue;
      final name = tags['name'] is String
          ? (tags['name'] as String).trim()
          : '';
      result.add(
        RoutePlace(
          id,
          name.isEmpty ? kind : name.substring(0, name.length.clamp(0, 100)),
          kind,
          point,
          along,
          best,
        ),
      );
    }
    result.sort((a, b) => a.alongMeters.compareTo(b.alongMeters));
    return result;
  }
}
