import 'dart:math' as math;

import 'bike_setup.dart';
import 'brake_load.dart';

class GearSuggestion {
  const GearSuggestion(
    this.front,
    this.rear,
    this.frontTeeth,
    this.rearTeeth,
    this.cadence,
  );
  final int front, rear, frontTeeth, rearTeeth;
  final double cadence;
  String get label => 'Спереди $front · сзади $rear ($frontTeeth/$rearTeeth)';
}

class BikeDrivetrain {
  const BikeDrivetrain({
    this.front = const [24, 34, 42],
    this.rear = const [28, 24, 22, 20, 18, 16, 14],
    this.circumference = 2.1,
    this.targetCadence = 80,
    this.setup = const BikeSetup(),
    this.gearsConfigured = true,
  });
  // Передние звёзды: от маленькой к большой. Задние: от большой к маленькой.
  final List<int> front, rear;
  final double circumference, targetCadence;
  final BikeSetup setup;
  final bool gearsConfigured;
  BikeDrivetrain withSetup(BikeSetup value) => BikeDrivetrain(
    front: front,
    rear: rear,
    circumference: circumference,
    targetCadence: targetCadence,
    setup: value,
    gearsConfigured: gearsConfigured,
  );
  int get speeds => front.length * rear.length;
  factory BikeDrivetrain.fromJson(dynamic value) {
    if (value is! Map || value.isEmpty) return const BikeDrivetrain();
    List<int> teeth(dynamic raw, List<int> fallback, bool ascending) {
      if (raw is! List) return fallback;
      final list =
          raw
              .whereType<num>()
              .map((n) => n.toInt())
              .where((n) => n >= 8 && n <= 80)
              .toSet()
              .toList()
            ..sort();
      if (list.isEmpty) return fallback;
      return ascending ? list : list.reversed.toList();
    }

    return BikeDrivetrain(
      setup: BikeSetup.fromJson(value['setup']),
      gearsConfigured: value['gears_configured'] != false,
      front: teeth(value['front'], const [24, 34, 42], true),
      rear: teeth(value['rear'], const [28, 24, 22, 20, 18, 16, 14], false),
      circumference: ((value['circumference'] as num?)?.toDouble() ?? 2.1)
          .clamp(1.0, 3.0),
      targetCadence: ((value['cadence'] as num?)?.toDouble() ?? 80).clamp(
        40,
        120,
      ),
    );
  }
  Map<String, dynamic> toJson() => {
    'front': front,
    'rear': rear,
    'circumference': circumference,
    'cadence': targetCadence,
    'setup': setup.toJson(),
    'gears_configured': gearsConfigured,
  };
  GearSuggestion? suggest(double speedKmh) {
    if (!gearsConfigured) return null;
    if (!speedKmh.isFinite || speedKmh < 3) return null;
    GearSuggestion? best;
    var bestScore = double.infinity;
    for (var f = 0; f < front.length; f++) {
      for (var r = 0; r < rear.length; r++) {
        if (front.length > 1 &&
            rear.length >= 5 &&
            ((f == 0 && r >= rear.length - 2) ||
                (f == front.length - 1 && r < 2))) {
          continue;
        }
        final cadence =
            speedKmh / 3.6 * 60 / circumference * rear[r] / front[f];
        // Одинаковые отношения выбираем с меньшим перекосом цепи.
        final frontPosition = front.length == 1 ? .5 : f / (front.length - 1);
        final rearPosition = rear.length == 1 ? .5 : r / (rear.length - 1);
        final crossChain = (frontPosition - rearPosition).abs();
        final score =
            (cadence - targetCadence).abs() +
            (front.length > 1 ? crossChain * 12 : 0);
        if (score < bestScore) {
          bestScore = score;
          best = GearSuggestion(f + 1, r + 1, front[f], rear[r], cadence);
        }
      }
    }
    return best;
  }
}

class BikePart {
  const BikePart({
    required this.id,
    required this.name,
    this.intervalKm = 0,
    this.intervalDays = 0,
    this.lastServiceAt,
    this.lastServiceKm = 0,
    this.condition,
    this.x = .5,
    this.y = .5,
    this.history = const [],
    this.templateId,
    this.brand = '',
    this.model = '',
    this.massGrams = 0,
    this.installedKm,
    this.priorKm = 0,
    this.installedAt,
    this.intervalHours = 0,
    this.lastServiceHours,
    this.installedHours,
    this.priorHours = 0,
  });
  final String id, name;
  final String? templateId;
  final String brand, model;
  final double massGrams, priorKm;
  final double? installedKm;
  final DateTime? installedAt;
  final double intervalHours, priorHours;
  final double? lastServiceHours, installedHours;
  double? usedHours(double totalHours) => lastServiceHours == null
      ? null
      : math.max(0, totalHours - lastServiceHours!);
  double? lifetimeHours(double totalHours) => installedHours == null
      ? null
      : priorHours + math.max(0, totalHours - installedHours!);
  String serviceStatus(double odometer, double totalHours) {
    if (brakeInspection?.limitReached == true) {
      return 'Достигнут предел толщины';
    }
    final values = <String>[];
    if (intervalKm > 0) {
      values.add(
        '${math.max(0, intervalKm - usedKm(odometer)).toStringAsFixed(0)} км',
      );
    }
    if (intervalHours > 0) {
      final hours = usedHours(totalHours);
      values.add(
        hours == null
            ? 'укажите отметку часов'
            : '${math.max(0, intervalHours - hours).toStringAsFixed(1)} ч',
      );
    }
    final days = daysRemaining();
    if (days != null) values.add('${math.max(0, days)} дн.');
    if (due(odometer, totalHours: totalHours)) return 'Пора проверить';
    return values.isEmpty
        ? 'Напоминание не настроено'
        : 'До проверки: ${values.join(' · ')}';
  }

  BikePartTemplate get template => BikePartTemplate.find(templateId ?? id);
  bool get acceptsBrakeMeasurement => [
    'front_pads',
    'rear_pads',
    'front_rotor',
    'rear_rotor',
  ].contains(template.id);
  BrakeInspection? get brakeInspection {
    if (!acceptsBrakeMeasurement) return null;
    final replacementDates =
        history
            .where((h) => h['action'] == 'Замена')
            .map((h) => DateTime.tryParse('${h['at']}'))
            .whereType<DateTime>()
            .toList()
          ..sort();
    final replacedAt = replacementDates.lastOrNull ?? installedAt;
    final measurements =
        history
            .where((h) => h['action'] == 'Замер')
            .map(BrakeInspection.fromJson)
            .whereType<BrakeInspection>()
            .where((m) => replacedAt == null || m.at.isAfter(replacedAt))
            .toList()
          ..sort((a, b) => b.at.compareTo(a.at));
    return measurements.firstOrNull;
  }

  double lifetimeKm(double odometer) =>
      priorKm + math.max(0, odometer - (installedKm ?? lastServiceKm));
  final double intervalKm, lastServiceKm, x, y;
  final int intervalDays;
  final DateTime? lastServiceAt;
  DateTime? get serviceDate =>
      lastServiceAt ??
      history
          .where((e) => e['action'] != 'Замер')
          .map((e) => DateTime.tryParse(e['at']?.toString() ?? ''))
          .whereType<DateTime>()
          .firstOrNull;
  DateTime? get nextServiceDate {
    final date = serviceDate?.toLocal();
    return date == null || intervalDays <= 0
        ? null
        : DateTime(date.year, date.month, date.day + intervalDays);
  }

  int? daysRemaining({DateTime? now}) {
    final date = nextServiceDate;
    if (date == null) return null;
    final today = (now ?? DateTime.now()).toLocal();
    return DateTime.utc(
      date.year,
      date.month,
      date.day,
    ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  }

  double get serviceCostRubles => history.fold(0.0, (sum, item) {
    final cost = item['cost'];
    return sum +
        (cost is num && cost.isFinite && cost >= 0 && item['currency'] == 'RUB'
            ? cost.toDouble()
            : 0.0);
  });
  final String? condition;
  final List<Map<String, dynamic>> history;
  double usedKm(double odometer) => math.max(0, odometer - lastServiceKm);
  double? usedFraction(double odometer) =>
      intervalKm > 0 ? (usedKm(odometer) / intervalKm).clamp(0, 1) : null;
  bool due(double odometer, {DateTime? now, double? totalHours}) =>
      brakeInspection?.limitReached == true ||
      (intervalKm > 0 && usedKm(odometer) >= intervalKm) ||
      (intervalHours > 0 &&
          totalHours != null &&
          (usedHours(totalHours) ?? -1) >= intervalHours) ||
      ((daysRemaining(now: now) ?? 1) <= 0);
  factory BikePart.fromJson(Map value) => BikePart(
    intervalHours: _finite(value['interval_hours'], 0, 100000),
    lastServiceHours: value['last_service_hours'] is num
        ? _finite(value['last_service_hours'], 0, 1e9)
        : null,
    installedHours: value['installed_hours'] is num
        ? _finite(value['installed_hours'], 0, 1e9)
        : null,
    priorHours: _finite(value['prior_hours'], 0, 1e9),
    templateId: value['template_id'] as String?,
    brand: value['brand'] as String? ?? '',
    model: value['model'] as String? ?? '',
    massGrams: _finite(value['mass_g'], 0, 100000),
    installedKm: value['installed_km'] is num
        ? _finite(value['installed_km'], 0, 1e9)
        : null,
    priorKm: _finite(value['prior_km'], 0, 1e9),
    installedAt: DateTime.tryParse(value['installed_at']?.toString() ?? ''),
    id: value['id']?.toString() ?? '',
    name: value['name']?.toString() ?? 'Деталь',
    intervalKm: ((value['interval'] as num?)?.toDouble() ?? 0).clamp(0, 100000),
    intervalDays: ((value['interval_days'] as num?)?.toInt() ?? 0).clamp(
      0,
      3650,
    ),
    lastServiceAt: DateTime.tryParse(
      value['last_service_at']?.toString() ?? '',
    ),
    lastServiceKm: math.max(0, (value['last_km'] as num?)?.toDouble() ?? 0),
    condition: value['condition'] as String?,
    x: ((value['x'] as num?)?.toDouble() ?? .5).clamp(.03, .97),
    y: ((value['y'] as num?)?.toDouble() ?? .5).clamp(.03, .97),
    history: (value['history'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(),
  );
  Map<String, dynamic> toJson() => {
    'interval_hours': intervalHours,
    'last_service_hours': lastServiceHours,
    'installed_hours': installedHours,
    'prior_hours': priorHours,
    'template_id': templateId,
    'brand': brand,
    'model': model,
    'mass_g': massGrams,
    'installed_km': installedKm,
    'prior_km': priorKm,
    'installed_at': installedAt?.toUtc().toIso8601String(),
    'id': id,
    'name': name,
    'interval': intervalKm,
    'interval_days': intervalDays,
    'last_service_at': lastServiceAt?.toUtc().toIso8601String(),
    'last_km': lastServiceKm,
    'condition': condition,
    'x': x,
    'y': y,
    'history': history,
  };
  BikePart copyWith({
    int? intervalDays,
    DateTime? lastServiceAt,
    String? name,
    double? intervalKm,
    double? lastServiceKm,
    String? condition,
    double? x,
    double? y,
    List<Map<String, dynamic>>? history,
    String? templateId,
    String? brand,
    String? model,
    double? massGrams,
    double? installedKm,
    double? priorKm,
    DateTime? installedAt,
    double? intervalHours,
    double? lastServiceHours,
    double? installedHours,
    double? priorHours,
  }) => BikePart(
    intervalHours: intervalHours ?? this.intervalHours,
    lastServiceHours: lastServiceHours ?? this.lastServiceHours,
    installedHours: installedHours ?? this.installedHours,
    priorHours: priorHours ?? this.priorHours,
    templateId: templateId ?? this.templateId,
    brand: brand ?? this.brand,
    model: model ?? this.model,
    massGrams: massGrams ?? this.massGrams,
    installedKm: installedKm ?? this.installedKm,
    priorKm: priorKm ?? this.priorKm,
    installedAt: installedAt ?? this.installedAt,
    id: id,
    intervalDays: intervalDays ?? this.intervalDays,
    lastServiceAt: lastServiceAt ?? this.lastServiceAt,
    name: name ?? this.name,
    intervalKm: intervalKm ?? this.intervalKm,
    lastServiceKm: lastServiceKm ?? this.lastServiceKm,
    condition: condition ?? this.condition,
    x: x ?? this.x,
    y: y ?? this.y,
    history: history ?? this.history,
  );
  static List<BikePart> initial(double odometer) => [
    BikePart(
      id: 'chain',
      name: 'Цепь',
      lastServiceKm: odometer,
      x: .43,
      y: .70,
    ),
    BikePart(
      id: 'cassette',
      name: 'Кассета',
      lastServiceKm: odometer,
      x: .23,
      y: .67,
    ),
    BikePart(
      id: 'brakes',
      name: 'Тормоза',
      lastServiceKm: odometer,
      x: .72,
      y: .48,
    ),
    BikePart(
      id: 'front_tyre',
      name: 'Передняя покрышка',
      lastServiceKm: odometer,
      x: .82,
      y: .74,
    ),
    BikePart(
      id: 'rear_tyre',
      name: 'Задняя покрышка',
      lastServiceKm: odometer,
      x: .16,
      y: .74,
    ),
    BikePart(
      id: 'fork',
      name: 'Вилка',
      lastServiceKm: odometer,
      x: .70,
      y: .38,
    ),
    BikePart(
      id: 'bottom_bracket',
      name: 'Каретка',
      lastServiceKm: odometer,
      x: .48,
      y: .68,
    ),
  ];
  static double _finite(dynamic v, double min, double max) =>
      v is num && v.isFinite ? v.toDouble().clamp(min, max) : min;
}
