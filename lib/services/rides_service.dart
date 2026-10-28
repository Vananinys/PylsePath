import '../models/workout_details.dart';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'activity_service.dart';
import '../models/activity_type.dart';
import '../models/transport_type.dart';
import '../models/progress_period.dart';
import '../models/saved_route.dart';
import '../utils/gpx_utils.dart';

/// Ошибка сервиса заездов с готовым для UI текстом.
class RidesServiceException implements Exception {
  const RidesServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Единственная работа с таблицей `rides` (INSERT + чтение истории).
///
/// Колонки: id, user_id, distance_km, duration_seconds, calories,
/// elevation_gain, gpx_data, vehicle_id (nullable), transport_type, created_at.
///
/// Колонок title/activity_type/route_points в таблице НЕТ: заголовок, тип
/// активности и трек восстанавливаются в [rideFromRow].
class RidesService {
  static const String _selectColumns =
      'id, user_id, distance_km, duration_seconds, calories, elevation_gain, '
      'gpx_data, vehicle_id, transport_type, created_at, workout_details, activity_local_day';

  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  static bool get isAvailable => _client != null;

  String? get userId => _client?.auth.currentUser?.id;

  /// Строка для INSERT. Публичная и чистая — проверяется тестами.
  static Map<String, dynamic> buildRow({
    required String userId,
    String? rideId,
    required double distanceKm,
    // Исправлено: теперь durationSeconds всегда приводится к int
    required int durationSeconds,
    double calories = 0,
    double elevationGain = 0,
    String? gpxData,
    String? vehicleId,
    String? transportType,
    DateTime? createdAt,
    Map<String, dynamic>? workoutDetails,
  }) {
    final recordedAt = createdAt ?? DateTime.now();
    return <String, dynamic>{
      if (workoutDetails != null) 'workout_details': workoutDetails,
      if (rideId != null) 'id': rideId,
      'user_id': userId,
      'distance_km': _round(distanceKm, 3),
      'duration_seconds': durationSeconds < 0 ? 0 : durationSeconds,
      'calories': calories.isFinite ? calories.clamp(0, 2147483647).round() : 0,
      'elevation_gain': elevationGain.isFinite
          ? elevationGain.clamp(0, 2147483647).round()
          : 0,
      'gpx_data': gpxData,
      // nullable: заезд может быть без привязанной техники.
      'vehicle_id': (vehicleId == null || vehicleId.isEmpty) ? null : vehicleId,
      'transport_type': (transportType == null || transportType.isEmpty)
          ? ActivityType.mountainBiking.name
          : transportType,
      'created_at': recordedAt.toUtc().toIso8601String(),
      'activity_local_day':
          workoutDetails?['activity_local_day'] as String? ??
          _localActivityDay(recordedAt),
    };
  }

  static String _localActivityDay(DateTime date) {
    final local = date.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  /// Сохраняет заезд текущего пользователя. Возвращает id записи или null.
  ///
  /// [trackPoints] сериализуются в GPX; [vehicleId]/[transportType] описывают
  /// технику и тип активности текущей сессии поездки.
  Future<String?> saveRide({
    String? rideId,
    String? expectedUserId,
    required double distanceKm,
    required int durationSeconds,
    double calories = 0,
    double elevationGain = 0,
    List<LatLng> trackPoints = const [],
    String? vehicleId,
    String? transportType,
    DateTime? createdAt,
    Map<String, dynamic>? workoutDetails,
  }) async {
    final client = _client;
    if (client == null) {
      debugPrint('[RidesService] Supabase недоступен — заезд не отправлен');
      return null;
    }

    final id = client.auth.currentUser?.id;
    if (id == null || (expectedUserId != null && id != expectedUserId)) {
      debugPrint('[RidesService] нет сессии — заезд сохранён только локально');
      return null;
    }

    final gpxData = trackPoints.isEmpty
        ? null
        : GpxUtils.build(
            points: trackPoints,
            segmentStarts: WorkoutDetails.fromJson(workoutDetails)
                .segmentStarts,
          );
    Future<String> upsert({required String? rideVehicleId}) async {
      final inserted = await client
          .from(AppConfig.ridesTable)
          .upsert(
            buildRow(
              workoutDetails: workoutDetails,
              userId: id,
              rideId: rideId,
              distanceKm: distanceKm,
              durationSeconds: durationSeconds,
              calories: calories,
              elevationGain: elevationGain,
              gpxData: gpxData,
              vehicleId: rideVehicleId,
              transportType: transportType,
              createdAt: createdAt,
            ),
          )
          .select('id')
          .single()
          .timeout(const Duration(seconds: 15));
      return (inserted['id'] ?? '').toString();
    }

    try {
      try {
        await ActivityService().configure();
      } catch (error) {
        debugPrint('[Activity] timezone update deferred: $error');
      }
      final insertedRideId = await upsert(rideVehicleId: vehicleId);
      debugPrint('[RidesService] заезд сохранён в облако ($insertedRideId)');
      return insertedRideId;
    } on PostgrestException catch (error) {
      debugPrint('[RidesService] insert ${error.code}: ${error.message}');
      final message = error.message.toLowerCase();
      final staleVehicleReference =
          vehicleId != null &&
          ((error.code == '23503' &&
                  (message.contains('vehicle') ||
                      message.contains('garage'))) ||
              message.contains('vehicle does not belong to ride owner'));
      if (staleVehicleReference) {
        try {
          final insertedRideId = await upsert(rideVehicleId: null);
          debugPrint(
            '[RidesService] заезд сохранён без удалённой техники ($insertedRideId)',
          );
          return insertedRideId;
        } catch (fallbackError) {
          debugPrint(
            '[RidesService] insert without vehicle failed: $fallbackError',
          );
        }
      }
      return null;
    } catch (error) {
      debugPrint('[RidesService] insert failed: $error');
      return null;
    }
  }

  Future<bool> deleteRide(
    String rideId, {
    required String expectedUserId,
  }) async {
    final client = _client;
    if (client == null || client.auth.currentUser?.id != expectedUserId) {
      return false;
    }
    try {
      await client
          .from(AppConfig.ridesTable)
          .delete()
          .eq('id', rideId)
          .eq('user_id', expectedUserId)
          .timeout(const Duration(seconds: 15));
      return true;
    } catch (error) {
      debugPrint('[RidesService] delete failed: $error');
      return false;
    }
  }

  /// История заездов пользователя, свежие сверху (`created_at DESC`).
  ///
  /// [period] ограничивает выборку текущим окном периода (день/неделя/месяц/
  /// год); `null` — вся история.
  Future<List<SavedRoute>> fetchRides({
    ProgressPeriod? period,
    bool throwOnError = false,
  }) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) {
      if (throwOnError) throw StateError('Нет подключения к аккаунту');
      return const [];
    }

    try {
      var query = client
          .from(AppConfig.ridesTable)
          .select(_selectColumns)
          .eq('user_id', id);

      if (period != null) {
        final since = period
            .windowStart(DateTime.now())
            .toUtc()
            .toIso8601String();
        query = query.gte('created_at', since);
      }

      final rides = <SavedRoute>[];
      const pageSize = 500;
      var offset = 0;
      while (true) {
        final rows = await query
            .order('created_at', ascending: false)
            .order('id', ascending: true)
            .range(offset, offset + pageSize - 1);
        rides.addAll(
          rows
              .map((row) => rideFromRow(Map<String, dynamic>.from(row)))
              .whereType<SavedRoute>(),
        );
        if (rows.length < pageSize) break;
        offset += rows.length;
      }
      return rides;
    } on PostgrestException catch (error) {
      debugPrint('[RidesService] fetch ${error.code}: ${error.message}');
      if (throwOnError) rethrow;
      return const [];
    } catch (error) {
      debugPrint('[RidesService] fetch failed: $error');
      if (throwOnError) rethrow;
      return const [];
    }
  }

  /// Преобразует строку `rides` в локальную модель [SavedRoute].
  /// Публичная и чистая — проверяется тестами.
  static SavedRoute? rideFromRow(Map<String, dynamic> row) {
    final createdAt = _parseDate(row['created_at']);
    if (createdAt == null) return null;

    final track = GpxUtils.parseTrack(row['gpx_data'] as String?);
    final points = track.points;
    final distanceKm = _toDouble(row['distance_km']);
    final durationSeconds = _toInt(row['duration_seconds']);
    final calories = _toDouble(row['calories']);
    final elevationGain = _toDouble(row['elevation_gain']);

    // Тип активности хранится именем ActivityType; неизвестное значение — МТБ.
    final rawType = row['transport_type'] as String?;
    var activityType = TransportType.fromDb(rawType).activityType;
    for (final type in ActivityType.values) {
      if (type.name == rawType) {
        activityType = type;
        break;
      }
    }

    var details = WorkoutDetails.fromJson(row['workout_details']);
    // Keep every index in the same coordinate space as the filtered GPX.
    final remapped = <int, int>{
      for (var i = 0; i < track.sourcePointIndices.length; i++)
        track.sourcePointIndices[i]: i,
    };
    final boundaries = <int>{
      ...track.segmentStarts,
      for (final old in details.segmentStarts)
        if (remapped.containsKey(old)) remapped[old]!,
    }.toList()..sort();
    details = WorkoutDetails.fromJson({
      ...details.toJson(),
      'segment_starts': boundaries,
      'ride_moments': [
        for (final moment in details.rideMoments)
          if (remapped.containsKey(moment.pointIndex))
            {...moment.toJson(), 'point_index': remapped[moment.pointIndex]},
      ],
      'samples': [
        for (final sample in details.samples)
          {
            ...sample.toJson(),
            'track_point_index': remapped[sample.trackPointIndex],
          },
      ],
    });
    final title = row['workout_details'] is Map
        ? row['workout_details']['title']
        : null;
    return SavedRoute(
      workoutDetails: details,
      activityLocalDay: row['activity_local_day'] as String?,
      // Колонки title в таблице нет — собираем понятный заголовок из даты.
      localId: row['id']?.toString(),
      distanceMeters: distanceKm * 1000,
      durationSeconds: durationSeconds,
      calories: calories,
      vehicleId: row['vehicle_id'] as String?,
      transportType: rawType,
      title: title is String && title.trim().isNotEmpty
          ? title.trim()
          : 'Тренировка ${_formatDateTime(createdAt)}',
      distance: '${distanceKm.toStringAsFixed(2)} км',
      duration: _formatDuration(durationSeconds),
      surfaceSummary: _summary(calories, elevationGain),
      // Финиш — последняя точка трека; если трека нет, ставим нулевую точку,
      // чтобы карточка истории осталась работоспособной.
      finishPoint: points.isNotEmpty ? points.last : const LatLng(0, 0),
      routePoints: points,
      activityType: activityType,
      createdAt: createdAt,
      elevationGainMeters: elevationGain,
      remoteId: (row['id'] ?? '').toString(),
      // Заезд из облака по определению синхронизирован.
      cloudSynced: true,
    );
  }

  static String _summary(double calories, double elevationGain) {
    final parts = <String>['Заезд из облака'];
    if (calories > 0) parts.add('${calories.round()} ккал');
    if (elevationGain > 0) parts.add('набор ${elevationGain.round()} м');
    return parts.join(' · ');
  }

  static String _formatDuration(int seconds) {
    if (seconds <= 0) return '0 мин';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0) return '$hours ч $minutes мин';
    return '$minutes мин';
  }

  static String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static DateTime? _parseDate(Object? value) {
    if (value is String) return DateTime.tryParse(value)?.toLocal();
    if (value is DateTime) return value.toLocal();
    return null;
  }

  static double _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  static int _toInt(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  /// Суммарный пробег заездов за период (для прогресса по цели).
  Future<double> totalDistance({ProgressPeriod? period}) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return 0;

    try {
      var query = client
          .from(AppConfig.ridesTable)
          .select('distance_km')
          .eq('user_id', id);
      if (period != null) {
        final since = period
            .windowStart(DateTime.now())
            .toUtc()
            .toIso8601String();
        query = query.gte('created_at', since);
      }

      var total = 0.0;
      const pageSize = 1000;
      var offset = 0;
      while (true) {
        final rows = await query
            .order('created_at', ascending: true)
            .order('id', ascending: true)
            .range(offset, offset + pageSize - 1);
        for (final raw in rows) {
          final row = Map<String, dynamic>.from(raw);
          final value = row['distance_km'];
          if (value is num) total += value.toDouble();
        }
        if (rows.length < pageSize) break;
        offset += rows.length;
      }
      return total;
    } on PostgrestException catch (error) {
      debugPrint('[RidesService] total ${error.code}: ${error.message}');
      return 0;
    } catch (error) {
      debugPrint('[RidesService] total failed: $error');
      return 0;
    }
  }

  static num _round(double value, int digits) {
    if (!value.isFinite) return 0;
    final factor = _pow10(digits);
    return (value * factor).round() / factor;
  }

  static double _pow10(int digits) {
    var result = 1.0;
    for (var i = 0; i < digits; i++) {
      result *= 10;
    }
    return result;
  }
}
