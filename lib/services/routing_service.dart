import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart' hide Path;
import 'package:flutter/material.dart';

import '../config.dart';
import '../models/route_step.dart';
import '../models/activity_type.dart';

class RoutingException implements Exception {
  const RoutingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// OSRM routing with separate car/bike/foot graphs.
/// Bike/foot default to FOSSGIS and may be overridden at build time.
class RoutingService {
  static bool validPoint(LatLng point) =>
      point.latitude.isFinite &&
      point.longitude.isFinite &&
      point.latitude.abs() <= 90 &&
      point.longitude.abs() <= 180;
  static double snapRadius(ActivityType activity) => activity.isFoot
      ? 200
      : activity == ActivityType.driving
      ? 500
      : 300;
  static LatLng _coordinate(dynamic raw) {
    if (raw is! List || raw.length < 2 || raw[0] is! num || raw[1] is! num)
      throw const RoutingException(
        'Сервис вернул повреждённые координаты маршрута.',
      );
    final point = LatLng(
      (raw[1] as num).toDouble(),
      (raw[0] as num).toDouble(),
    );
    if (!validPoint(point))
      throw const RoutingException(
        'Сервис вернул некорректные координаты маршрута.',
      );
    return point;
  }

  RoutingService({this.client});
  final http.Client? client;
  static DateTime? _lastRequestAt;
  static Future<void> _requestTail = Future.value();

  Future<http.Response> _get(Uri uri) async {
    final previous = _requestTail;
    final released = Completer<void>();
    _requestTail = released.future;
    await previous;
    try {
      final last = _lastRequestAt;
      if (last != null) {
        final wait =
            const Duration(seconds: 1) - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      _lastRequestAt = DateTime.now();
      return await (client?.get(
                uri,
                headers: {'User-Agent': 'PulsePath/1.0'},
              ) ??
              http.get(uri, headers: {'User-Agent': 'PulsePath/1.0'}))
          .timeout(_httpTimeout);
    } on http.ClientException {
      throw const RoutingException(
        'Нет связи с сервисом маршрутов. Проверьте интернет и повторите.',
      );
    } finally {
      released.complete();
    }
  }

  static String _baseFor(ActivityType activity) {
    final base = activity == ActivityType.driving
        ? AppConfig.osrmCarUrl
        : activity.isFoot
        ? AppConfig.osrmFootUrl
        : AppConfig.osrmBikeUrl;
    if (base.isEmpty) {
      throw StateError(
        'Для ${activity.label} нужен сервер маршрутов с соответствующим профилем. '
        'Настройте OSRM_BIKE_URL или OSRM_FOOT_URL.',
      );
    }
    return base.replaceFirst(RegExp(r'/+$'), '');
  }

  /// Корень сервиса для Match API (без /route/v1).

  /// Публичный OSRM не принимает больше ~100 координат за запрос.
  static const int _matchMaxPoints = 100;

  /// Таймаут HTTP-запроса. Без него зависший сокет держал построение
  /// маршрута неопределённо долго — пользователь видел вечный спиннер.
  /// [Future.timeout] бросает [TimeoutException], который вызывающий код
  /// (MapNavigationController.buildRoute) ловит и показывает снекбар.
  static const Duration _httpTimeout = Duration(seconds: 15);

  Future<RoutingResult> buildRoute({
    required LatLng start,
    required LatLng end,
    required ActivityType activity,
    List<LatLng> via = const [],
  }) {
    if (!validPoint(start) ||
        !validPoint(end) ||
        via.any((p) => !validPoint(p)))
      throw const RoutingException(
        'Выберите корректные координаты начала, финиша и остановок.',
      );
    if (via.length > 8)
      throw const RoutingException('Можно добавить до 8 остановок.');
    return _buildRouteViaOSRM(start, end, activity, via);
  }

  /// Road snapping changes the length; the requested distance is approximate.
  Future<({RoutingResult route, List<LatLng> via})> buildRoundTrip({
    required LatLng start,
    required double distanceKm,
    required double bearing,
    required ActivityType activity,
  }) async {
    var guess = distanceKm;
    ({RoutingResult route, List<LatLng> via})? best;
    var bestError = double.infinity;
    for (var attempt = 0; attempt < 3; attempt++) {
      final via = roundTripWaypoints(start, guess, bearing);
      try {
        final route = await buildRoute(
          start: start,
          end: start,
          activity: activity,
          via: via,
        );
        final error = (route.distanceKm - distanceKm).abs() / distanceKm;
        if (error < bestError) {
          best = (route: route, via: via);
          bestError = error;
        }
        if (error <= .15) break;
        if (route.distanceKm <= 0) break;
        guess = (guess * distanceKm / route.distanceKm).clamp(2.0, 150.0);
      } catch (_) {
        if (best == null) rethrow;
        break;
      }
    }
    return best!;
  }

  static List<LatLng> roundTripWaypoints(
    LatLng start,
    double distanceKm,
    double bearing,
  ) {
    if (!validPoint(start)) throw ArgumentError('Некорректная начальная точка');
    if (!distanceKm.isFinite ||
        distanceKm < 2 ||
        distanceKm > 150 ||
        !bearing.isFinite) {
      throw ArgumentError('Выберите дистанцию от 2 до 150 км');
    }
    const geo = Distance();
    final radiusMeters = distanceKm * 1000 / 3 / 1.25;
    return [
      geo.offset(start, radiusMeters, bearing - 30),
      geo.offset(start, radiusMeters, bearing + 30),
    ];
  }

  /// Привязывает записанный трек к дорогам (OSRM Match API) — Этап B.
  ///
  /// Возвращает привязанные точки или null (нет сети/не совпало/мало точек) —
  /// тогда сохраняем сырой трек как есть.
  Future<List<LatLng>?> matchTrack(
    List<LatLng> points, {
    ActivityType activity = ActivityType.cycling,
  }) async {
    // Raw workout tracks remain the authoritative data. Matching is optional.
    if (points.length < 4 || points.length > _matchMaxPoints) return null;
    try {
      final base = _baseFor(activity);
      final profile = _osrmProfile(activity);
      final coords = points
          .map((p) => '${p.longitude},${p.latitude}')
          .join(';');
      final response = await _get(
        Uri.parse(
          '$base/match/v1/$profile/$coords'
          '?geometries=geojson&overview=full',
        ),
      );
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final matchings = data['matchings'] as List?;
      if (data['code'] != 'Ok' || matchings == null || matchings.length != 1) {
        return null;
      }
      return (matchings.single['geometry']['coordinates'] as List)
          .map(
            (c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
          )
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Профиль OSRM по типу активности.
  ///
  /// Публичный демо-сервер OSRM физически обслуживает только car-данные:
  /// алиасы foot/bike указаны для семантики и сразу работают с self-hosted
  /// инстансом, где загружены соответствующие профили. Раньше все
  /// велосипедные типы эмулировались пешком ('foot') — теперь им соответствует
  /// 'bike'.
  static String _osrmProfile(ActivityType activity) {
    // The instance URL selects the actual bike/foot/car graph.
    // FOSSGIS uses /driving for all its OSRM instances.
    return 'driving';
  }

  Future<RoutingResult> _buildRouteViaOSRM(
    LatLng start,
    LatLng end,
    ActivityType activity,
    List<LatLng> via,
  ) async {
    final profile = _osrmProfile(activity);
    final inputs = [start, ...via, end];
    final radius = snapRadius(activity);
    final url = Uri.parse(
      '${_baseFor(activity)}/route/v1/$profile/'
      '${[start, ...via, end].map((p) => '${p.longitude},${p.latitude}').join(';')}'
      '?overview=full&geometries=geojson&steps=true&radiuses=${List.filled(inputs.length, radius.toInt()).join(';')}',
    );

    final response = await _get(url);
    dynamic data;
    if (response.statusCode == 429)
      throw const RoutingException(
        'Сервис маршрутов занят. Повторите немного позже.',
      );
    if (response.statusCode >= 500)
      throw const RoutingException(
        'Сервис маршрутов временно недоступен. Повторите позже.',
      );
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      throw const RoutingException(
        'Сервис маршрутов вернул некорректный ответ. Повторите позже.',
      );
    }
    if (data is Map && data['code'] == 'NoSegment')
      throw const RoutingException(
        'Рядом с одной из точек нет доступной дороги для выбранного вида активности. Переместите точку ближе к дороге или тропе.',
      );
    if (data is Map && data['code'] == 'NoRoute')
      throw const RoutingException(
        'Между выбранными точками нет доступного маршрута. Проверьте остановки и вид активности.',
      );
    if (response.statusCode != 200) {
      throw RoutingException(
        response.statusCode == 429
            ? 'Сервис маршрутов занят. Повторите немного позже.'
            : 'Сервис маршрутов недоступен (${response.statusCode}).',
      );
    }

    if (data is! Map || data['code'] != 'Ok') {
      throw const RoutingException(
        'Не найден доступный маршрут. Выберите другую точку.',
      );
    }
    if (data['routes'] is! List || (data['routes'] as List).isEmpty) {
      throw const RoutingException(
        'Сервис не вернул маршрут. Повторите выбор точек.',
      );
    }

    final bestRoute = data['routes'][0];
    if (bestRoute is! Map ||
        bestRoute['geometry'] is! Map ||
        bestRoute['geometry']['coordinates'] is! List ||
        bestRoute['distance'] is! num)
      throw const RoutingException('Сервис вернул неполный маршрут.');
    final coordinates = bestRoute['geometry']['coordinates'] as List;
    final distanceMeters = (bestRoute['distance'] as num).toDouble();
    if (coordinates.length < 2 ||
        coordinates.length > 200000 ||
        !distanceMeters.isFinite ||
        distanceMeters < 0)
      throw const RoutingException(
        'Сервис вернул некорректную длину или геометрию маршрута.',
      );
    final waypoints = data['waypoints'];
    if (waypoints is List) {
      if (waypoints.length != inputs.length)
        throw const RoutingException('Сервис пропустил одну из остановок.');
      for (var i = 0; i < waypoints.length; i++) {
        final waypoint = waypoints[i];
        if (waypoint is! Map)
          throw const RoutingException('Сервис вернул некорректную остановку.');
        final d = waypoint['distance'];
        final location = waypoint['location'];
        if ((d is num && (!d.isFinite || d < 0 || d > radius + 2)) ||
            (location != null &&
                const Distance()(inputs[i], _coordinate(location)) >
                    radius + 2))
          throw const RoutingException(
            'Маршрут слишком далеко от выбранной точки. Переместите её ближе к дороге.',
          );
      }
    }
    final distanceKm = distanceMeters / 1000.0;
    final duration = bestRoute['duration'];
    final durationMin =
        activity == ActivityType.driving &&
            duration is num &&
            duration.isFinite &&
            duration > 0
        ? duration.toDouble() / 60
        : (distanceKm / activity.avgSpeedKmH) * 60.0;

    final routePoints = coordinates.map(_coordinate).toList();
    if (const Distance()(start, routePoints.first) > radius + 20 ||
        const Distance()(end, routePoints.last) > radius + 20)
      throw const RoutingException(
        'Начало или конец маршрута слишком далеко от выбранной точки.',
      );

    final steps = <RouteStep>[];
    final viaOffsets = <double>[];
    var legOffset = 0.0;
    var routeOffsetMeters = 0.0;
    final legs = bestRoute['legs'] is List
        ? bestRoute['legs'] as List
        : const [];
    if (legs.isNotEmpty && legs.length != inputs.length - 1)
      throw const RoutingException(
        'Сервис вернул неполную последовательность остановок.',
      );
    for (var legIndex = 0; legIndex < legs.length; legIndex++) {
      final leg = legs[legIndex];
      if (leg is! Map ||
          leg['distance'] is! num ||
          !(leg['distance'] as num).isFinite ||
          (leg['distance'] as num) < 0)
        throw const RoutingException(
          'Сервис вернул некорректный участок маршрута.',
        );
      for (final raw
          in (leg['steps'] is List ? leg['steps'] as List : const [])) {
        if (raw is! Map ||
            raw['distance'] is! num ||
            !(raw['distance'] as num).isFinite ||
            (raw['distance'] as num) < 0)
          continue;
        if (raw['maneuver'] is! Map || raw['maneuver']['location'] is! List) {
          routeOffsetMeters += (raw['distance'] as num).toDouble();
          continue;
        }
        final maneuver = raw['maneuver'] as Map;
        final location = maneuver['location'] as List;
        final stepLocation = _coordinate(location);
        final type = maneuver['type']?.toString() ?? '';
        final modifier = maneuver['modifier']?.toString() ?? '';
        final street = raw['name']?.toString() ?? '';
        final isDestinationLeg = legIndex == legs.length - 1;
        final exit = maneuver['exit'];
        final isRoundabout = type == 'roundabout' || type == 'rotary';
        final instruction = switch (type) {
          'arrive' =>
            isDestinationLeg ? 'Вы прибыли' : 'Промежуточная точка достигнута',
          'depart' => 'Начните движение',
          'roundabout' || 'rotary' =>
            exit is num
                ? 'На круговом перекрёстке выберите $exit-й съезд'
                : 'На круговом перекрёстке выберите нужный съезд',
          'exit roundabout' ||
          'exit rotary' => 'Съезжайте с кругового перекрёстка',
          _ when modifier == 'uturn' => 'Развернитесь',
          _ when type == 'fork' && modifier.contains('left') =>
            'Держитесь левее',
          _ when type == 'fork' && modifier.contains('right') =>
            'Держитесь правее',
          _ when modifier == 'slight left' => 'Плавно поверните налево',
          _ when modifier == 'slight right' => 'Плавно поверните направо',
          _ when modifier == 'sharp left' => 'Резко поверните налево',
          _ when modifier == 'sharp right' => 'Резко поверните направо',
          _ when modifier.contains('left') => 'Поверните налево',
          _ when modifier.contains('right') => 'Поверните направо',
          _ when modifier == 'straight' => 'Продолжайте движение',
          _ => 'Продолжайте движение',
        };
        final icon = type == 'arrive' && isDestinationLeg
            ? Icons.flag
            : modifier == 'uturn'
            ? Icons.u_turn_left
            : isRoundabout || type == 'exit roundabout' || type == 'exit rotary'
            ? Icons.alt_route
            : modifier.contains('left')
            ? Icons.turn_left
            : modifier.contains('right')
            ? Icons.turn_right
            : Icons.straight;
        steps.add(
          RouteStep(
            instruction: instruction,
            streetName: street,
            icon: icon,
            location: stepLocation,
            distance: (raw['distance'] as num).toDouble(),
            routeOffsetMeters: routeOffsetMeters,
          ),
        );
        routeOffsetMeters += (raw['distance'] as num).toDouble();
      }
      legOffset += (leg['distance'] as num).toDouble();
      viaOffsets.add(legOffset);
    }
    if (viaOffsets.isNotEmpty) viaOffsets.removeLast();
    return RoutingResult(
      points: routePoints,
      steps: steps,
      distanceKm: distanceKm,
      durationMin: durationMin,
      viaOffsetsMeters: viaOffsets,
    );
  }
}

class RoutingResult {
  final List<LatLng> points;
  final List<RouteStep> steps;
  final double distanceKm;
  final double durationMin;
  final List<double> viaOffsetsMeters;

  RoutingResult({
    required this.points,
    required this.steps,
    required this.distanceKm,
    required this.durationMin,
    this.viaOffsetsMeters = const [],
  });
}
