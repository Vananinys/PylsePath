import 'activity_type.dart';
import 'transport_type.dart';
import 'user_profile.dart';
import 'bike_equipment.dart';

/// Техника пользователя из таблицы `garage`.
///
/// Колонки сверены с проектом: id, user_id, title, type, weight_kg,
/// wheel_size, total_distance, is_active, photo_url, created_at.
///
/// `transport_type` хранится строкой — именем [ActivityType] (например
/// 'mountainBiking'), чтобы техника и заезды описывались одним словарём.
class Vehicle {
  const Vehicle({
    required this.id,
    required this.userId,
    required this.name,
    required this.transportType,
    this.weightKg = 0,
    this.wheelSize = 29,
    this.totalDistance = 0,
    this.recordedHours = 0,
    this.isActive = false,
    this.isEbike = false,
    this.photoUrl,
    this.createdAt,
    this.isPublic = false,
    this.parts = const [],
    this.drivetrain,
  });

  final String id;
  final String userId;
  final String name;

  /// Тип транспорта — имя [ActivityType] ('mountainBiking', 'roadCycling', ...).
  final String transportType;

  final double weightKg;
  final double wheelSize;
  final double totalDistance;

  /// Active duration of saved cloud rides; not mechanical engine hours.
  final double recordedHours;

  /// Признак выбранной (активной) техники. Активной может быть только одна.
  final bool isActive;

  /// Электропривод: свойство техники, а не настройка заезда
  /// (калории считаются с половинным расходом).
  final bool isEbike;

  /// Публичный URL фото в бакете `vehicles`.
  final String? photoUrl;

  final DateTime? createdAt;
  final bool isPublic;
  final List<BikePart> parts;
  final BikeDrivetrain? drivetrain;

  /// Активность для расчёта маршрута/калорий.
  ///
  /// Старые записи хранили имя [ActivityType], новые — лейбл [TransportType].
  /// Неизвестное значение трактуем как МТБ.
  ActivityType get activityType {
    for (final type in ActivityType.values) {
      if (type.name == transportType) return type;
    }
    return TransportType.fromDb(transportType).activityType;
  }

  /// Соответствующий тип велосипеда для локального UI гаража.
  BikeType get bikeType {
    switch (activityType) {
      case ActivityType.roadCycling:
        return BikeType.road;
      case ActivityType.gravelRiding:
        return BikeType.gravel;
      case ActivityType.cycling:
      case ActivityType.hiking:
      case ActivityType.running:
      case ActivityType.trailRunning:
      case ActivityType.briskWalking:
      case ActivityType.nordicWalking:
      case ActivityType.trekking:
        return BikeType.city;
      case ActivityType.mountainBiking:
      case ActivityType.bikepacking:
      case ActivityType.driving:
        return BikeType.hardtail;
    }
  }

  /// Обратный маппинг типа велосипеда в строку `transport_type`.
  static String transportTypeFor(BikeType type) {
    switch (type) {
      case BikeType.road:
      case BikeType.roadLegacy:
        return ActivityType.roadCycling.name;
      case BikeType.gravel:
      case BikeType.gravelLegacy:
        return ActivityType.gravelRiding.name;
      case BikeType.city:
        return ActivityType.cycling.name;
      case BikeType.hardtail:
      case BikeType.semiFat:
      case BikeType.fatbike:
      case BikeType.mountain:
        return ActivityType.mountainBiking.name;
    }
  }

  /// Локальная модель велосипеда (для гаражного UI и профиля).
  Bike toBike() => Bike(
    id: id,
    name: name,
    weightKg: weightKg,
    type: bikeType,
    wheelSize: wheelSize,
    totalDistance: totalDistance,
    isEbike: isEbike,
  );

  /// Строка `garage` → модель. Публичная и чистая — проверяется тестами.
  static Vehicle fromRow(Map<String, dynamic> row) {
    // Название и тип — колонки `title` и `type`; `name`/`transport_type`
    // читаем для совместимости со старыми записями/кэшами.
    final rawName = (row['title'] ?? row['name']) as String?;
    final rawType = (row['type'] ?? row['transport_type']) as String?;
    return Vehicle(
      id: (row['id'] ?? '').toString(),
      userId: (row['user_id'] ?? '').toString(),
      name: rawName == null || rawName.trim().isEmpty
          ? 'Транспорт'
          : rawName.trim(),
      transportType: rawType == null || rawType.trim().isEmpty
          ? ActivityType.mountainBiking.name
          : rawType.trim(),
      weightKg: _toDouble(row['weight_kg']),
      wheelSize: _doubleOrDefault(row['wheel_size'], 29),
      totalDistance: _toDouble(row['total_distance']),
      recordedHours: _toDouble(row['recorded_hours']),
      isActive: _toBool(row['is_active']),
      isEbike: _toBool(row['is_ebike']),
      photoUrl: row['photo_url'] as String?,
      createdAt: _parseDate(row['created_at']),
      isPublic: _toBool(row['is_public']),
      parts: (row['maintenance'] as List? ?? [])
          .whereType<Map>()
          .map(BikePart.fromJson)
          .toList(),
      drivetrain:
          row['drivetrain'] is Map && (row['drivetrain'] as Map).isNotEmpty
          ? BikeDrivetrain.fromJson(row['drivetrain'])
          : null,
    );
  }

  /// Модель → строка для INSERT/UPDATE `garage` (без id: его выдаёт БД).
  Map<String, dynamic> toRow({required String userId}) => <String, dynamic>{
    'user_id': userId,
    'title': name,
    'type': transportType,
    'weight_kg': _num(weightKg),
    'wheel_size': _num(wheelSize),
    'total_distance': _num(totalDistance),
    'is_active': isActive,
    'is_ebike': isEbike,
    'is_public': isPublic,
    'maintenance': parts.map((p) => p.toJson()).toList(),
    'drivetrain': drivetrain?.toJson() ?? {},
    // Локальный путь в URL-колонку не пишем — только настоящую ссылку.
    if (_isHttpUrl(photoUrl)) 'photo_url': photoUrl,
  };

  Vehicle copyWith({
    String? id,
    String? userId,
    String? name,
    String? transportType,
    double? weightKg,
    double? wheelSize,
    double? totalDistance,
    double? recordedHours,
    bool? isActive,
    bool? isEbike,
    String? photoUrl,
    bool clearPhoto = false,
    DateTime? createdAt,
    bool? isPublic,
    List<BikePart>? parts,
    BikeDrivetrain? drivetrain,
  }) {
    return Vehicle(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      transportType: transportType ?? this.transportType,
      weightKg: weightKg ?? this.weightKg,
      wheelSize: wheelSize ?? this.wheelSize,
      totalDistance: totalDistance ?? this.totalDistance,
      recordedHours: recordedHours ?? this.recordedHours,
      isActive: isActive ?? this.isActive,
      isEbike: isEbike ?? this.isEbike,
      photoUrl: clearPhoto ? null : (photoUrl ?? this.photoUrl),
      createdAt: createdAt ?? this.createdAt,
      isPublic: isPublic ?? this.isPublic,
      parts: parts ?? this.parts,
      drivetrain: drivetrain ?? this.drivetrain,
    );
  }

  static double _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  static double _doubleOrDefault(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? fallback;
    return fallback;
  }

  static bool _toBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.toLowerCase();
      return normalized == 'true' || normalized == '1' || normalized == 't';
    }
    return false;
  }

  static DateTime? _parseDate(Object? value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  static num _num(double value) {
    if (!value.isFinite) return 0;
    return value == value.roundToDouble() ? value.round() : value;
  }

  static bool _isHttpUrl(String? value) =>
      value != null &&
      (value.startsWith('http://') || value.startsWith('https://'));
}
