import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'package:http/http.dart' as http;

class GeocodingService {
  GeocodingService({http.Client? client}) : _client = client;
  final http.Client? _client;
  static final Map<String, String> _localities = {};

  static Map<String, String> searchParameters(
    String query, {
    LatLng? center,
    bool nearbyOnly = true,
  }) {
    final parameters = <String, String>{
      'format': 'jsonv2',
      'q': query.trim(),
      'limit': '8',
      'accept-language': 'ru',
      'addressdetails': '1',
    };
    if (center != null && nearbyOnly) {
      const latitudeDelta = 25 / 111.32;
      final longitudeDelta =
          latitudeDelta /
          math.max(.01, math.cos(center.latitude * math.pi / 180));
      parameters['viewbox'] = [
        (center.longitude - longitudeDelta).clamp(-180, 180),
        (center.latitude + latitudeDelta).clamp(-90, 90),
        (center.longitude + longitudeDelta).clamp(-180, 180),
        (center.latitude - latitudeDelta).clamp(-90, 90),
      ].join(',');
      parameters['bounded'] = '1';
    }
    return parameters;
  }

  Future<String?> locality(LatLng center) async {
    final key =
        '${center.latitude.toStringAsFixed(2)},${center.longitude.toStringAsFixed(2)}';
    if (_localities.containsKey(key)) return _localities[key];
    final result = _tail.then((_) async {
      await _waitForSlot();
      try {
        final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
          'format': 'jsonv2',
          'lat': '${center.latitude}',
          'lon': '${center.longitude}',
          'accept-language': 'ru',
          'zoom': '14',
          'addressdetails': '1',
        });
        final response =
            await (_client?.get(uri, headers: {'User-Agent': _userAgent}) ??
                    http.get(uri, headers: {'User-Agent': _userAgent}))
                .timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) return null;
        final address = (jsonDecode(response.body) as Map)['address'] as Map?;
        if (address == null) return null;
        final city =
            address['city'] ??
            address['town'] ??
            address['village'] ??
            address['hamlet'];
        if (city is! String) return null;
        final district = address['suburb'] ?? address['city_district'];
        final label = district is String ? '$city · $district' : city;
        _localities[key] = label;
        if (_localities.length > 100)
          _localities.remove(_localities.keys.first);
        return label;
      } catch (_) {
        return null;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  static Future<void> _waitForSlot() async {
    final last = _lastRequest;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < const Duration(seconds: 1)) {
        await Future<void>.delayed(const Duration(seconds: 1) - elapsed);
      }
    }
    _lastRequest = DateTime.now();
  }

  static Future<void> _tail = Future.value();
  static DateTime? _lastRequest;
  static final Map<String, List<Map<String, dynamic>>> _cache = {};
  Future<List<Map<String, dynamic>>> searchPlaces(
    String query, {
    LatLng? center,
    bool nearbyOnly = true,
  }) {
    final parameters = searchParameters(
      query,
      center: center,
      nearbyOnly: nearbyOnly,
    );
    final key = Uri(queryParameters: parameters).query;
    if (query.trim().isEmpty) return Future.value([]);
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);
    final result = _tail.then((_) async {
      await _waitForSlot();
      final rows = await _requestPlaces(parameters);
      if (center != null && nearbyOnly) {
        const distance = Distance();
        rows.sort(
          (a, b) =>
              distance(
                center,
                LatLng(double.parse(a['lat']), double.parse(a['lon'])),
              ).compareTo(
                distance(
                  center,
                  LatLng(double.parse(b['lat']), double.parse(b['lon'])),
                ),
              ),
        );
      }
      if (rows.isNotEmpty) {
        _cache[key] = rows;
        if (_cache.length > 100) _cache.remove(_cache.keys.first);
      }
      return rows;
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  static const String _nominatimUrl =
      'https://nominatim.openstreetmap.org/search';

  /// User-Agent обязателен по правилам Nominatim (иначе 403) — название
  /// приложения + контакт/платформа.
  static const String _userAgent =
      'PulsePathApp/1.0 (flutter; contact: dev@pulsepath.app)';

  Future<List<Map<String, dynamic>>> _requestPlaces(
    Map<String, String> parameters,
  ) async {
    final url = Uri.parse(_nominatimUrl).replace(queryParameters: parameters);

    try {
      final response =
          await (_client?.get(url, headers: {'User-Agent': _userAgent}) ??
                  http.get(url, headers: {'User-Agent': _userAgent}))
              .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        return data.cast<Map<String, dynamic>>();
      }
    } on TimeoutException {
      // Медленный ответ — показываем «ничего не найдено».
    } catch (_) {
      // ignore network errors
    }
    return [];
  }
}
