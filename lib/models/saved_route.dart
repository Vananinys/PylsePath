import 'workout_details.dart';
import 'route_step.dart';

import 'package:latlong2/latlong.dart' hide Path;

import 'activity_type.dart';
import '../utils/ride_id.dart';

class SavedRoute {
  final List<RouteStep> navigationSteps;
  final List<LatLng> viaPoints;
  final bool isFavorite;
  final String collection;
  final String routeNotes;
  final WorkoutDetails workoutDetails;
  final String localId;
  final double? distanceMeters;
  final int? durationSeconds;
  final double calories;
  final String? vehicleId;
  final String? transportType;
  final String title;
  final String distance;
  final String duration;
  final String surfaceSummary;
  final LatLng finishPoint;
  final List<LatLng> routePoints;
  final ActivityType activityType;

  /// Когда заезд был сохранён. Может быть `null` у записей, созданных до
  /// появления поля, — тогда дата берётся из заголовка (см. [dateTime]).
  final DateTime? createdAt;

  /// Calendar day recorded by the owner, stable after travelling/timezone changes.
  final String? activityLocalDay;

  /// Реальный набор высоты за заезд (метры, сумма положительных дельт GPS-
  /// высоты). 0 — данных о высоте не было (старые записи, заезд из облака
  /// без elevation_gain).
  final double elevationGainMeters;

  /// id строки в таблице `rides`, если заезд уже уехал в облако.
  /// Используется для точной дедупликации при mergeRemote.
  final String? remoteId;

  /// Уехал ли заезд в Supabase (`rides`). false — сохранён только локально
  /// (офлайн/ошибка сети) и ждёт повторной отправки.
  bool cloudSynced;

  SavedRoute({
    this.viaPoints = const [],
    this.isFavorite = false,
    this.collection = '',
    this.routeNotes = '',
    this.navigationSteps = const [],
    this.workoutDetails = const WorkoutDetails(),
    String? localId,
    this.distanceMeters,
    this.durationSeconds,
    this.calories = 0,
    this.vehicleId,
    this.transportType,
    required this.title,
    required this.distance,
    required this.duration,
    required this.surfaceSummary,
    required this.finishPoint,
    required this.routePoints,
    required this.activityType,
    this.createdAt,
    String? activityLocalDay,
    this.elevationGainMeters = 0,
    this.remoteId,
    this.cloudSynced = false,
  }) : localId = localId ?? newRideId(),
       activityLocalDay =
           activityLocalDay ??
           (createdAt == null ? null : _calendarDay(createdAt));

  static String _calendarDay(DateTime date) {
    final local = date.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  /// Дата заезда для статистики по периодам (день/неделя/месяц/год).
  ///
  /// У старых записей дата лежит в заголовке — их создавали как
  /// «Тренировка 2026-09-30 15:41», поэтому она разбирается регуляркой и
  /// история не «выпадает» из статистики. Если даты нет совсем, считаем
  /// запись свежей (лучше показать её в текущем периоде, чем потерять).
  DateTime get dateTime => createdAt ?? _dateFromTitle() ?? DateTime.now();

  /// Unknown legacy dates must not keep renewing a daily activity streak.
  DateTime? get recordedDateTime => createdAt ?? _dateFromTitle();

  static final RegExp _titleDatePattern = RegExp(
    r'(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})',
  );

  DateTime? _dateFromTitle() {
    final match = _titleDatePattern.firstMatch(title);
    if (match == null) return null;
    return DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
    );
  }

  /// Дистанция в километрах: в JSON она хранится строкой («12.5 км»).
  ///
  /// Единственный парсер дистанции в приложении: все, кому нужно число,
  /// используют этот геттер (профиль, история, детали заезда).
  double get distanceKm {
    if (distanceMeters != null) return distanceMeters! / 1000;
    final text = distance.toLowerCase().replaceAll(',', '.').trim();
    final value =
        double.tryParse(text.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;
    // «3830 м» — метры, «12.5 км» — километры (в «км» тоже есть буква «м»,
    // поэтому сначала проверяем километры).
    if (!text.contains('км') && text.contains('м')) return value / 1000.0;
    return value;
  }

  /// Длительность в минутах из строки («1 ч 23 мин», «45 мин», «01:23:45»).
  double get durationMin {
    if (durationSeconds != null) return durationSeconds! / 60;
    final text = duration.trim();
    // Формат «01:23:45» / «12:34» (активная панель заезда).
    final clock = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$').firstMatch(text);
    if (clock != null) {
      final h = int.parse(clock.group(1)!);
      final m = int.parse(clock.group(2)!);
      final s = int.tryParse(clock.group(3) ?? '0') ?? 0;
      return clock.group(3) == null ? h + m / 60.0 : h * 60.0 + m + s / 60.0;
    }
    final hours = RegExp(r'(\d+)\s*ч').firstMatch(text)?.group(1) ?? '0';
    final minutes = RegExp(r'(\d+)\s*мин').firstMatch(text)?.group(1) ?? '0';
    final seconds = RegExp(r'(\d+)\s*сек').firstMatch(text)?.group(1) ?? '0';
    return (int.tryParse(hours) ?? 0) * 60.0 +
        (int.tryParse(minutes) ?? 0) +
        (int.tryParse(seconds) ?? 0) / 60.0;
  }

  /// Formats old and new recordings without rewriting stored history.
  String get displayDuration => workoutDurationLabel(
    Duration(seconds: durationSeconds ?? (durationMin * 60).round()),
  );

  Map<String, dynamic> toJson() => {
    'viaPoints': viaPoints.map((p) => [p.latitude, p.longitude]).toList(),
    'isFavorite': isFavorite,
    'collection': collection,
    'routeNotes': routeNotes,
    'navigationSteps': navigationSteps.map((s) => s.toJson()).toList(),
    'localId': localId,
    'workoutDetails': workoutDetails.toJson(),
    'distanceMeters': distanceMeters,
    'durationSeconds': durationSeconds,
    'calories': calories,
    'vehicleId': vehicleId,
    'transportType': transportType,
    'title': title,
    'distance': distance,
    'duration': duration,
    'surfaceSummary': surfaceSummary,
    'finishLat': finishPoint.latitude,
    'finishLon': finishPoint.longitude,
    'routePoints': routePoints.map((p) => [p.latitude, p.longitude]).toList(),
    // Тип храним по имени: числовой индекс молча ломается при вставке
    // нового значения в середину enum'а.
    // Исправлено: теперь дата сохраняется в формате ISO, чтобы при чтении
    // она интерпретировалась корректно (вместо миллисекунд от эпохи JS)
    'activityType': activityType.name,
    'createdAt': createdAt?.toIso8601String(),
    'activityLocalDay': activityLocalDay,
    'elevationGain': elevationGainMeters,
    'remoteId': remoteId,
    'cloudSynced': cloudSynced,
  };

  factory SavedRoute.fromJson(Map<String, dynamic> json) {
    // Track indices are shared by moments and GPS segment boundaries.
    // Reject damage instead of silently shifting those indices.
    final rawPoints = json['routePoints'];
    if (rawPoints is! List) {
      throw const FormatException('Отсутствуют точки трека');
    }
    final pointsList = <LatLng>[];
    for (final p in rawPoints) {
      if (p is! List ||
          p.length != 2 ||
          p[0] is! num ||
          p[1] is! num ||
          !(p[0] as num).isFinite ||
          !(p[1] as num).isFinite ||
          (p[0] as num).abs() > 90 ||
          (p[1] as num).abs() > 180) {
        throw const FormatException('Повреждена точка трека');
      }
      pointsList.add(
        LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
      );
    }
    // Новый формат — ISO-строка; легаси — миллисекунды от эпохи (num).
    final rawCreatedAt = json['createdAt'];
    final DateTime? createdAt = switch (rawCreatedAt) {
      final String s => DateTime.tryParse(s),
      final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
      _ => null,
    };
    LatLng? finish;
    final finishLat = json['finishLat'];
    final finishLon = json['finishLon'];
    if (finishLat is num &&
        finishLon is num &&
        finishLat.isFinite &&
        finishLon.isFinite &&
        finishLat.abs() <= 90 &&
        finishLon.abs() <= 180) {
      finish = LatLng(finishLat.toDouble(), finishLon.toDouble());
    } else if (pointsList.isNotEmpty) {
      finish = pointsList.last;
    }
    return SavedRoute(
      viaPoints: (json['viaPoints'] as List? ?? [])
          .where(
            (p) =>
                p is List &&
                p.length == 2 &&
                p[0] is num &&
                p[1] is num &&
                (p[0] as num).isFinite &&
                (p[1] as num).isFinite &&
                (p[0] as num).abs() <= 90 &&
                (p[1] as num).abs() <= 180,
          )
          .take(8)
          .map(
            (p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
          )
          .toList(),
      isFavorite: json['isFavorite'] == true,
      collection: json['collection'] is String
          ? json['collection'] as String
          : '',
      routeNotes: json['routeNotes'] is String
          ? json['routeNotes'] as String
          : '',
      navigationSteps: (json['navigationSteps'] as List? ?? [])
          .map(RouteStep.fromJson)
          .whereType<RouteStep>()
          .toList(),
      workoutDetails: WorkoutDetails.fromJson(json['workoutDetails']),
      localId: json['localId'] as String? ?? json['remoteId'] as String?,
      distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
      durationSeconds: (json['durationSeconds'] as num?)?.toInt(),
      calories: (json['calories'] as num?)?.toDouble() ?? 0,
      vehicleId: json['vehicleId'] as String?,
      transportType: json['transportType'] as String?,
      title: json['title'] as String? ?? '',
      distance: json['distance'] as String? ?? '',
      duration: json['duration'] as String? ?? '',
      surfaceSummary: json['surfaceSummary'] as String? ?? '',
      finishPoint: finish ?? const LatLng(0, 0),
      routePoints: pointsList,
      // Имя типа — новый формат; числовой индекс — легаси (старые записи).
      activityType: _activityTypeFromJson(json),
      activityLocalDay: json['activityLocalDay'] as String?,
      createdAt: createdAt,
      elevationGainMeters: (json['elevationGain'] as num?)?.toDouble() ?? 0,
      remoteId: json['remoteId'] as String?,
      cloudSynced: json['cloudSynced'] as bool? ?? false,
    );
  }

  static ActivityType _activityTypeFromJson(Map<String, dynamic> json) {
    final name = json['activityType'];
    if (name is String) {
      for (final type in ActivityType.values) {
        if (type.name == name) return type;
      }
    }
    // Легаси: в старых записях лежал индекс enum'а.
    final index = json['activityIndex'] ?? json['activityType'];
    if (index is int && index >= 0 && index < ActivityType.values.length) {
      return ActivityType.values[index];
    }
    return ActivityType.mountainBiking;
  }

  /// Копия с обновлёнными полями облачной синхронизации (id записи в `rides`,
  /// флаг «уехал в облако»). Остальные поля иммутабельны.
  SavedRoute withSyncState({String? remoteId, required bool cloudSynced}) {
    return SavedRoute(
      viaPoints: viaPoints,
      isFavorite: isFavorite,
      collection: collection,
      routeNotes: routeNotes,
      navigationSteps: navigationSteps,
      workoutDetails: workoutDetails,
      localId: localId,
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
      calories: calories,
      vehicleId: vehicleId,
      transportType: transportType,
      title: title,
      distance: distance,
      duration: duration,
      surfaceSummary: surfaceSummary,
      finishPoint: finishPoint,
      routePoints: routePoints,
      activityType: activityType,
      createdAt: createdAt,
      elevationGainMeters: elevationGainMeters,
      remoteId: remoteId ?? this.remoteId,
      cloudSynced: cloudSynced,
      activityLocalDay: activityLocalDay,
    );
  }

  /// Library metadata never replaces recorded telemetry or cloud identity.
  SavedRoute withLibraryDetails({
    String? title,
    bool? favorite,
    String? collection,
    String? notes,
  }) => SavedRoute(
    localId: localId,
    remoteId: remoteId,
    cloudSynced: cloudSynced,
    title: title ?? this.title,
    activityLocalDay: activityLocalDay,
    isFavorite: favorite ?? isFavorite,
    collection: collection ?? this.collection,
    routeNotes: notes ?? routeNotes,
    navigationSteps: navigationSteps,
    workoutDetails: workoutDetails,
    viaPoints: viaPoints,
    distanceMeters: distanceMeters,
    durationSeconds: durationSeconds,
    calories: calories,
    vehicleId: vehicleId,
    transportType: transportType,
    distance: distance,
    duration: duration,
    surfaceSummary: surfaceSummary,
    finishPoint: finishPoint,
    routePoints: routePoints,
    activityType: activityType,
    createdAt: createdAt,
    elevationGainMeters: elevationGainMeters,
  );
}
