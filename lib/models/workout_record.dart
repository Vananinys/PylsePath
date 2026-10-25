import 'saved_route.dart';

/// Расширенная запись заезда с дополнительными метриками.
class WorkoutRecord {
  final SavedRoute route;
  final double averageSpeed; // средняя скорость в км/ч
  final double maxSpeed; // максимальная скорость в км/ч
  final double elevationGain; // набор высоты в метрах
  final DateTime timestamp;

  WorkoutRecord({
    required this.route,
    required this.averageSpeed,
    required this.maxSpeed,
    required this.elevationGain,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Создаёт WorkoutRecord из SavedRoute.
  ///
  /// Средняя скорость считается из дистанции и длительности; максимальная
  /// скорость и набор высоты берутся из заезда, если они записаны, иначе 0 —
  /// UI показывает «нет данных», а не выдуманные значения.
  factory WorkoutRecord.fromSavedRoute(
    SavedRoute route, {
    double? averageSpeed,
    double? maxSpeed,
    double? elevationGain,
    DateTime? timestamp,
  }) {
    final hours = route.durationMin / 60.0;
    final computedAverage = hours > 0 ? route.distanceKm / hours : 0.0;
    return WorkoutRecord(
      route: route,
      averageSpeed: averageSpeed ?? computedAverage,
      maxSpeed: maxSpeed ?? route.workoutDetails.maxSpeedKmh,
      // Реальный набор высоты, записанный при заезде (0 — не было данных
      // о высоте, а не «ровный рельеф»; деталей экран это не различает).
      elevationGain: elevationGain ?? route.elevationGainMeters,
      // Если дата не передана, берём её из самого маршрута (а не «сейчас»),
      // чтобы в истории отображалось реальное время заезда.
      timestamp: timestamp ?? route.dateTime,
    );
  }

  Map<String, dynamic> toJson() => {
    'route': route.toJson(),
    'averageSpeed': averageSpeed,
    'maxSpeed': maxSpeed,
    'elevationGain': elevationGain,
    'timestamp': timestamp.toIso8601String(),
  };

  factory WorkoutRecord.fromJson(Map<String, dynamic> json) {
    return WorkoutRecord(
      route: SavedRoute.fromJson(json['route']),
      averageSpeed: (json['averageSpeed'] as num).toDouble(),
      maxSpeed: (json['maxSpeed'] as num).toDouble(),
      elevationGain: (json['elevationGain'] as num).toDouble(),
      timestamp: DateTime.parse(json['timestamp']),
    );
  }
}
