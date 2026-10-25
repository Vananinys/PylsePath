// Тесты чистых (без сети) хелперов сервисов синхронизации:
// маппинг строк `garage`/`rides`/`goals` и границы значений.
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/progress_period.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/user_profile.dart';
import 'package:pulsepath/models/vehicle.dart';
import 'package:pulsepath/services/goals_service.dart';
import 'package:pulsepath/services/rides_service.dart';
import 'package:pulsepath/utils/gpx_utils.dart';

void main() {
  group('Vehicle', () {
    test('fromRow читает колонки garage', () {
      final vehicle = Vehicle.fromRow(<String, dynamic>{
        'id': 'v1',
        'user_id': 'u1',
        'title': 'Горный',
        'type': 'mountainBiking',
        'weight_kg': 14,
        'wheel_size': 29,
        'total_distance': 123.5,
        'is_active': true,
        'photo_url': 'https://cdn/v.jpg',
      });
      expect(vehicle.id, 'v1');
      expect(vehicle.name, 'Горный');
      expect(vehicle.transportType, 'mountainBiking');
      expect(vehicle.activityType, ActivityType.mountainBiking);
      expect(vehicle.weightKg, 14);
      expect(vehicle.isActive, isTrue);
      expect(vehicle.photoUrl, 'https://cdn/v.jpg');
    });

    test(
      'fromRow поддерживает старые поля name/transport_type как fallback',
      () {
        final vehicle = Vehicle.fromRow(<String, dynamic>{
          'id': 'v2',
          'user_id': 'u1',
          'name': 'Старая запись',
          'transport_type': 'roadCycling',
        });
        expect(vehicle.name, 'Старая запись');
        expect(vehicle.transportType, 'roadCycling');
      },
    );

    test('toRow не пишет локальный путь в photo_url', () {
      const vehicle = Vehicle(
        id: 'v1',
        userId: 'u1',
        name: 'X',
        transportType: 'roadCycling',
        photoUrl: '/local/x.jpg',
      );
      final row = vehicle.toRow(userId: 'u1');
      expect(row.containsKey('photo_url'), isFalse);
      expect(row['type'], 'roadCycling');
      expect(row['title'], 'X');
      expect(row.containsKey('name'), isFalse);
      expect(row.containsKey('transport_type'), isFalse);
    });

    test('transportTypeFor маппит типы велосипедов', () {
      expect(
        Vehicle.transportTypeFor(BikeType.road),
        ActivityType.roadCycling.name,
      );
      expect(
        Vehicle.transportTypeFor(BikeType.gravel),
        ActivityType.gravelRiding.name,
      );
      expect(
        Vehicle.transportTypeFor(BikeType.city),
        ActivityType.cycling.name,
      );
      expect(
        Vehicle.transportTypeFor(BikeType.hardtail),
        ActivityType.mountainBiking.name,
      );
    });
  });

  group('RidesService.buildRow', () {
    test('vehicle_id null при пустом значении, transport по умолчанию', () {
      final row = RidesService.buildRow(
        userId: 'u1',
        distanceKm: 12.3456,
        durationSeconds: 3600,
        vehicleId: '',
      );
      expect(row['vehicle_id'], isNull);
      expect(row['transport_type'], ActivityType.mountainBiking.name);
      expect(row['distance_km'], 12.346);
    });

    test('vehicle_id и transport_type сохраняются', () {
      final row = RidesService.buildRow(
        userId: 'u1',
        distanceKm: 5,
        durationSeconds: 100,
        vehicleId: 'v1',
        transportType: 'gravelRiding',
      );
      expect(row['vehicle_id'], 'v1');
      expect(row['transport_type'], 'gravelRiding');
    });

    test('отрицательная длительность обрезается до нуля', () {
      final row = RidesService.buildRow(
        userId: 'u1',
        distanceKm: 1,
        durationSeconds: -5,
      );
      expect(row['duration_seconds'], 0);
    });
  });

  group('GoalsService', () {
    test('buildGoalRow: период строкой и обрезка цели', () {
      final row = GoalsService.buildGoalRow(
        userId: 'u1',
        period: ProgressPeriod.week,
        goalKm: 99999,
        now: DateTime.utc(2026, 1, 2, 3, 4),
      );
      expect(row['user_id'], 'u1');
      expect(row['period'], 'week');
      expect(row['goal_km'], ProgressPeriod.maxGoalKm);
      expect(row['updated_at'], '2026-01-02T03:04:00.000Z');
    });

    test('periodFromDb маппит строку, неизвестное — месяц', () {
      expect(GoalsService.periodFromDb('day'), ProgressPeriod.day);
      expect(GoalsService.periodFromDb('year'), ProgressPeriod.year);
      expect(GoalsService.periodFromDb('nonsense'), ProgressPeriod.month);
      expect(GoalsService.periodFromDb(null), ProgressPeriod.month);
    });
  });

  group('SavedRoute — парсеры и JSON', () {
    test('distanceKm понимает «км», «м» и запятую', () {
      final km = _route(distance: '12.5 км');
      expect(km.distanceKm, 12.5);
      final meters = _route(distance: '3830 м');
      expect(meters.distanceKm, closeTo(3.83, 0.0001));
      final comma = _route(distance: '12,5 км');
      expect(comma.distanceKm, 12.5);
    });

    test('durationMin понимает часы, минуты и формат активной панели', () {
      expect(_route(duration: '1 ч 23 мин').durationMin, 83.0);
      expect(_route(duration: '45 мин').durationMin, 45.0);
      expect(_route(duration: '01:23:45').durationMin, closeTo(83.75, 0.0001));
    });

    test('JSON round-trip: тип активности по имени, высота, флаг синка', () {
      final original = _route(
        distance: '10 км',
        duration: '30 мин',
        elevation: 128.0,
        remoteId: 'ride-1',
        cloudSynced: true,
      );
      final restored = SavedRoute.fromJson(original.toJson());
      expect(restored.activityType, ActivityType.mountainBiking);
      expect(restored.elevationGainMeters, 128.0);
      expect(restored.remoteId, 'ride-1');
      expect(restored.cloudSynced, isTrue);
    });

    test('JSON легаси: activityIndex читается, синк по умолчанию false', () {
      final legacy = _route(distance: '10 км', duration: '30 мин').toJson()
        ..remove('activityType')
        ..['activityIndex'] = ActivityType.roadCycling.index;
      final restored = SavedRoute.fromJson(legacy);
      expect(restored.activityType, ActivityType.roadCycling);
      expect(restored.cloudSynced, isFalse);
      expect(restored.elevationGainMeters, 0.0);
    });
  });

  group('RidesService.rideFromRow', () {
    test('читает transport_type и elevation_gain, ставит remoteId', () {
      final route = RidesService.rideFromRow(<String, dynamic>{
        'id': 'r-42',
        'user_id': 'u1',
        'distance_km': 21.5,
        'duration_seconds': 3600,
        'calories': 500,
        'elevation_gain': 210.4,
        'gpx_data': null,
        'vehicle_id': 'v1',
        'transport_type': 'roadCycling',
        'created_at': '2026-05-04T09:15:00.000Z',
      })!;
      expect(route.remoteId, 'r-42');
      expect(route.activityType, ActivityType.roadCycling);
      expect(route.elevationGainMeters, closeTo(210.4, 0.001));
      expect(route.cloudSynced, isTrue);
      expect(route.distanceKm, closeTo(21.5, 0.001));
    });

    test('неизвестный transport_type — МТБ; без created_at — null', () {
      final route = RidesService.rideFromRow(<String, dynamic>{
        'id': 'r-1',
        'distance_km': 5,
        'duration_seconds': 600,
        'created_at': '2026-05-04T09:15:00.000Z',
        'transport_type': 'hoverboard',
      })!;
      expect(route.activityType, ActivityType.mountainBiking);
      expect(RidesService.rideFromRow({'distance_km': 1}), isNull);
    });
  });

  group('GpxUtils', () {
    test('round-trip: build → parse возвращает те же точки', () {
      const points = [
        LatLng(52.123456, 13.654321),
        LatLng(52.223456, 13.754321),
        LatLng(52.323456, 13.854321),
      ];
      final gpx = GpxUtils.build(points: points);
      final parsed = GpxUtils.parse(gpx);
      expect(parsed.length, points.length);
      for (var i = 0; i < points.length; i++) {
        expect(parsed[i].latitude, closeTo(points[i].latitude, 0.000001));
        expect(parsed[i].longitude, closeTo(points[i].longitude, 0.000001));
      }
    });

    test('parse: null/пусто/мусор — пустой список, без исключений', () {
      expect(GpxUtils.parse(null), isEmpty);
      expect(GpxUtils.parse(''), isEmpty);
      expect(GpxUtils.parse('<not gpx/>'), isEmpty);
    });
  });
}

SavedRoute _route({
  String distance = '10 км',
  String duration = '30 мин',
  double elevation = 0,
  String? remoteId,
  bool cloudSynced = false,
}) {
  return SavedRoute(
    title: 'Тест',
    distance: distance,
    duration: duration,
    surfaceSummary: '',
    finishPoint: const LatLng(52, 13),
    routePoints: const [LatLng(52, 13)],
    activityType: ActivityType.mountainBiking,
    createdAt: DateTime.utc(2026, 5, 4, 9, 15),
    elevationGainMeters: elevation,
    remoteId: remoteId,
    cloudSynced: cloudSynced,
  );
}
