import 'dart:math' as math;

import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';

import '../models/activity_type.dart' as app_activity;

class GeoUtils {
  /// Вычисляет минимальное расстояние от точки до полилинии (списка отрезков).
  static double minDistanceToPolyline(LatLng point, List<LatLng> polyline) {
    if (polyline.isEmpty) return double.infinity;
    if (polyline.length == 1) return distanceBetween(point, polyline.single);
    double minDistance = double.infinity;

    for (int i = 0; i < polyline.length - 1; i++) {
      final dist = distanceToSegment(point, polyline[i], polyline[i + 1]);
      if (dist < minDistance) {
        minDistance = dist;
      }
    }
    return minDistance;
  }

  /// Вычисляет расстояние от точки p до отрезка ab.
  static double distanceToSegment(LatLng p, LatLng a, LatLng b) {
    final cosLat = math.cos(p.latitude * math.pi / 180);
    final ax = (a.longitude - p.longitude) * cosLat;
    final ay = a.latitude - p.latitude;
    final bx = (b.longitude - p.longitude) * cosLat;
    final by = b.latitude - p.latitude;
    final dx = bx - ax;
    final dy = by - ay;
    final l2 = dx * dx + dy * dy;
    if (l2 == 0) return distanceBetween(p, a);
    final t = (-(ax * dx + ay * dy) / l2).clamp(0.0, 1.0);
    return distanceBetween(
      p,
      LatLng(
        a.latitude + t * (b.latitude - a.latitude),
        a.longitude + t * (b.longitude - a.longitude),
      ),
    );
  }

  /// Квадрат расстояния между двумя точками в градусах (не метрах).
  /// Используется для вычислений проекции.
  static double distanceSquared(LatLng a, LatLng b) {
    final dy = b.latitude - a.latitude;
    final dx = b.longitude - a.longitude;
    return dx * dx + dy * dy;
  }

  /// Эвристический расчёт набора высоты и спуска на основе дистанции.
  /// Возвращает пару (gainMeters, lossMeters).
  static (int, int) estimateElevationChange(double distanceKm) {
    // Эмпирические коэффициенты: на каждые 10 км пути +120м набора, -100м спуска
    final gain = (distanceKm * 12.0).round();
    final loss = (distanceKm * 10.0).round();
    return (gain, loss);
  }

  /// Вычисляет расстояние между двумя точками в метрах.
  static double distanceBetween(LatLng a, LatLng b) {
    return Geolocator.distanceBetween(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
  }

  /// Вычисляет площадь ограничивающего прямоугольника (bounding box) для списка точек.
  /// Исправлено: теперь возвращаем null для пустого списка, чтобы не вводить карту в нулевую точку
  static ({double south, double north, double west, double east})?
  calculateBoundingBox(List<LatLng> points) {
    if (points.isEmpty) {
      return null;
    }
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLon = points.first.longitude;
    double maxLon = points.first.longitude;

    for (var p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return (south: minLat, north: maxLat, west: minLon, east: maxLon);
  }

  /// Расчёт сожжённых калорий по формуле MET (метаболический эквивалент задачи).
  /// weightKg – вес пользователя в кг,
  /// speedKmh – средняя скорость в км/ч,
  /// durationHours – продолжительность активности в часах,
  /// activity – тип активности (определяет базовый MET).
  /// Возвращает количество калорий (ккал).
  static double calculateCalories({
    required double weightKg,
    required double speedKmh,
    required double durationHours,
    required app_activity.ActivityType activity,
  }) {
    // Базовые MET для разных типов активности (значения приблизительные)
    double baseMET = 1.0; // default
    switch (activity) {
      case app_activity.ActivityType.mountainBiking:
        baseMET = 8.5;
        break;
      case app_activity.ActivityType.roadCycling:
        baseMET = 7.0;
        break;
      case app_activity.ActivityType.gravelRiding:
        baseMET = 7.5;
        break;
      case app_activity.ActivityType.bikepacking:
        baseMET = 6.0;
        break;
      case app_activity.ActivityType.cycling:
        baseMET = 5.0;
        break;
      case app_activity.ActivityType.hiking:
        baseMET = 4.0;
        break;
      case app_activity.ActivityType.running:
        baseMET = 9.0;
        break;
      case app_activity.ActivityType.driving:
        baseMET = 1.0;
        break;
      case app_activity.ActivityType.briskWalking:
        baseMET = 4.8;
        break;
      case app_activity.ActivityType.nordicWalking:
        baseMET = 4.3;
        break;
      case app_activity.ActivityType.trekking:
        baseMET = 5.3;
        break;
      case app_activity.ActivityType.trailRunning:
        baseMET = 9.3;
        break;
    }

    // Корректировка MET в зависимости от скорости
    // Для велосипедных активностей: увеличение MET на 0.1 за каждый км/ч сверх 10 км/ч
    if (activity == app_activity.ActivityType.mountainBiking ||
        activity == app_activity.ActivityType.roadCycling ||
        activity == app_activity.ActivityType.gravelRiding ||
        activity == app_activity.ActivityType.bikepacking ||
        activity == app_activity.ActivityType.cycling) {
      if (speedKmh > 10.0) {
        baseMET += (speedKmh - 10.0) * 0.1;
      }
    } else if (activity == app_activity.ActivityType.running) {
      if (speedKmh > 8.0) {
        baseMET += (speedKmh - 8.0) * 0.2;
      }
    } else if (activity == app_activity.ActivityType.hiking) {
      if (speedKmh > 4.0) {
        baseMET += (speedKmh - 4.0) * 0.15;
      }
    }

    // Формула: калории = MET * вес (кг) * время (часы)
    return baseMET * weightKg * durationHours;
  }
}
