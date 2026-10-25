import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart' hide Path;

import '../models/surface_info.dart';
import '../models/activity_type.dart';
import '../utils/geo_utils.dart';

class OverpassService {
  static const _url = 'https://overpass-api.de/api/interpreter';
  Future<SurfaceInfo?> fetchRouteSurface(
    List<LatLng> points,
    double distanceKm,
    ActivityType activity,
  ) async {
    if (points.length < 2) return null;
    try {
      // Исправлено: теперь обрабатываем null для пустого списка
      final bounds = GeoUtils.calculateBoundingBox(points);
      if (bounds == null) return null;
      final query =
          '[out:json][timeout:8];way["highway"]('
          '${bounds.south - .0002},${bounds.west - .0002},'
          '${bounds.north + .0002},${bounds.east + .0002});out tags geom;';
      final response = await http
          .post(Uri.parse(_url), body: query)
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return null;
      final elements = (jsonDecode(response.body)['elements'] as List);
      if (elements.length > 20000) return null;
      final ways = <({List<LatLng> geometry, int? category})>[];
      for (final el in elements) {
        final geometry = (el['geometry'] as List? ?? const [])
            .map(
              (p) => LatLng(
                (p['lat'] as num).toDouble(),
                (p['lon'] as num).toDouble(),
              ),
            )
            .toList();
        if (geometry.length < 2) continue;
        final surface = (el['tags']?['surface'] ?? '').toString().toLowerCase();
        final int? category =
            const {
              'asphalt',
              'paved',
              'concrete',
              'concrete:plates',
              'paving_stones',
            }.contains(surface)
            ? 0
            : const {
                'gravel',
                'fine_gravel',
                'compacted',
                'pebblestone',
              }.contains(surface)
            ? 1
            : const {
                'dirt',
                'earth',
                'ground',
                'unpaved',
                'grass',
                'sand',
                'mud',
              }.contains(surface)
            ? 2
            : null;
        ways.add((geometry: geometry, category: category));
      }
      final lengths = <double>[0, 0, 0];
      double total = 0, known = 0;
      // Bound work; long/dense routes return no data rather than inventing percentages.
      if (points.length > 2000 ||
          ways.fold<int>(0, (s, w) => s + w.geometry.length) * points.length >
              2000000) {
        return null;
      }
      for (var i = 1; i < points.length; i++) {
        final meters = GeoUtils.distanceBetween(points[i - 1], points[i]);
        if (meters <= 0) continue;
        total += meters;
        if (meters > 100) continue; // too sparse to classify reliably
        final midpoint = LatLng(
          (points[i - 1].latitude + points[i].latitude) / 2,
          (points[i - 1].longitude + points[i].longitude) / 2,
        );
        double best = 15;
        int? category;
        for (final way in ways) {
          final distance = GeoUtils.minDistanceToPolyline(
            midpoint,
            way.geometry,
          );
          if (distance < best) {
            best = distance;
            category = way.category;
          }
        }
        if (category != null) {
          lengths[category] += meters;
          known += meters;
        }
      }
      if (total <= 0 || known / total < .95) return null;
      return SurfaceInfo(
        asphaltPercent: lengths[0] / known * 100,
        gravelPercent: lengths[1] / known * 100,
        dirtPercent: lengths[2] / known * 100,
      );
    } catch (_) {
      return null;
    }
  }

  /// Количество светофоров на маршруте: узлы highway=traffic_signals
  /// в ~40 м от полилинии. null — нет данных Overpass (офлайн/ошибка).
  Future<int?> fetchTrafficSignals(List<LatLng> points) async {
    if (points.length < 2) return null;
    try {
      // Исправлено: теперь обрабатываем null для пустого списка
      final bounds = GeoUtils.calculateBoundingBox(points);
      if (bounds == null) return null;
      final query =
          '[out:json][timeout:8];node["highway"="traffic_signals"]('
          '${bounds.south - .001},${bounds.west - .001},'
          '${bounds.north + .001},${bounds.east + .001});out geom;';
      final response = await http
          .post(Uri.parse(_url), body: query)
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return null;
      final elements = jsonDecode(response.body)['elements'] as List;
      return countSignalsNearRoute(points, [
        for (final el in elements)
          (
            lat: (el['lat'] as num?)?.toDouble(),
            lon: (el['lon'] as num?)?.toDouble(),
          ),
      ]);
    } catch (_) {
      return null;
    }
  }

  /// Чистая функция подсчёта: сигналы в пределах 40 м от полилинии.
  /// Публичная и статическая — проверяется тестами.
  static int countSignalsNearRoute(
    List<LatLng> points,
    List<({double? lat, double? lon})> signals,
  ) {
    var count = 0;
    for (final signal in signals) {
      final lat = signal.lat, lon = signal.lon;
      if (lat == null || lon == null) continue;
      final point = LatLng(lat, lon);
      if (GeoUtils.minDistanceToPolyline(point, points) <= 40) count++;
    }
    return count;
  }

  /// Парковки видимой области: node/way amenity=parking.
  /// Для полигонов берём центроид геометрии.
  Future<List<({LatLng point, String name})>> fetchParkings({
    required double south,
    required double west,
    required double north,
    required double east,
  }) async {
    try {
      final query =
          '[out:json][timeout:10];('
          'node["amenity"="parking"]($south,$west,$north,$east);'
          'way["amenity"="parking"]($south,$west,$north,$east););out tags geom center 200;';
      final response = await http
          .post(Uri.parse(_url), body: query)
          .timeout(const Duration(seconds: 14));
      if (response.statusCode != 200) return const [];
      final elements = jsonDecode(response.body)['elements'] as List;
      return parseParkings(elements);
    } catch (_) {
      return const [];
    }
  }

  /// Чистый парсер ответа Overpass (проверяется тестами).
  static List<({LatLng point, String name})> parseParkings(
    List<dynamic> elements,
  ) {
    final result = <({LatLng point, String name})>[];
    for (final el in elements) {
      if (el is! Map<String, dynamic>) continue;
      final tags = el['tags'] as Map<String, dynamic>? ?? const {};
      final name = (tags['name'] as String?) ?? 'Парковка';
      final lat = (el['lat'] as num?)?.toDouble();
      final lon = (el['lon'] as num?)?.toDouble();
      if (lat != null && lon != null) {
        result.add((point: LatLng(lat, lon), name: name));
        continue;
      }
      // way: Overpass отдаёт центр по modifier `center`.
      final center = el['center'];
      if (center is Map<String, dynamic>) {
        final clat = (center['lat'] as num?)?.toDouble();
        final clon = (center['lon'] as num?)?.toDouble();
        if (clat != null && clon != null) {
          result.add((point: LatLng(clat, clon), name: name));
        }
      }
    }
    return result;
  }
}
