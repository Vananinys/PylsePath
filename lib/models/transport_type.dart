import 'activity_type.dart';
import 'user_profile.dart';

/// Тип транспорта для гаража (`garage.transport_type`).
///
/// Значение хранится строкой-лейблом («Велосипед», «Самокат») — так оно
/// читаемо в базе. Для маршрутизации/калорий и локального UI маппится в
/// [ActivityType]/[BikeType].
enum TransportType {
  bicycle('Велосипед', ActivityType.mountainBiking, BikeType.hardtail),
  scooter('Самокат', ActivityType.cycling, BikeType.city),
  running('Бег', ActivityType.running, BikeType.city),
  walking('Пешком', ActivityType.hiking, BikeType.city),
  other('Другое', ActivityType.mountainBiking, BikeType.hardtail);

  const TransportType(this.label, this.activityType, this.bikeType);

  /// Транспорт, который можно добавить в гараж.
  /// Бег и ходьба остаются доступными для чтения старых записей.
  static const garageOptions = [bicycle, scooter, other];

  /// Текст, который показываем в UI и пишем в `garage.transport_type`.
  final String label;

  /// Активность для расчёта маршрута/калорий.
  final ActivityType activityType;

  /// Соответствующий тип велосипеда для локальной модели.
  final BikeType bikeType;

  /// Тип транспорта по значению из БД. Неизвестное — [TransportType.other].
  static TransportType fromDb(Object? value) {
    final label = value?.toString();
    for (final type in TransportType.values) {
      if (type.label == label) return type;
    }
    return TransportType.other;
  }
}
