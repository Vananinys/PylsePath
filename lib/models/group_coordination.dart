import 'package:latlong2/latlong.dart';

enum GroupReadiness {
  waiting('Не подтвердил'),
  going('Буду'),
  late('Опаздываю'),
  ready('Готов');

  const GroupReadiness(this.label);
  final String label;
}

enum GroupSignalKind {
  wait('Подождите меня'),
  stopped('Остановился'),
  help('Нужна помощь'),
  okay('Всё нормально, продолжаю'),
  depart('Выезжаем'),
  stop('Предлагаю остановку');

  const GroupSignalKind(this.label);
  final String label;
}

enum GroupRideStyle {
  relaxed('Спокойная поездка'),
  training('Тренировка'),
  stops('С остановками');

  const GroupRideStyle(this.label);
  final String label;
}

LatLng? groupPoint(Object? lat, Object? lon) {
  if (lat is! num ||
      lon is! num ||
      !lat.isFinite ||
      !lon.isFinite ||
      lat.abs() > 90 ||
      lon.abs() > 180) {
    return null;
  }
  return LatLng(lat.toDouble(), lon.toDouble());
}

class GroupMeetPlan {
  const GroupMeetPlan({
    this.label = '',
    this.startsAt,
    this.style = GroupRideStyle.relaxed,
    this.point,
    this.departedAt,
  });
  final String label;
  final DateTime? startsAt;
  final GroupRideStyle style;
  final LatLng? point;
  final DateTime? departedAt;
  Map<String, dynamic> toPayload() => {
    'label': label.trim(),
    'starts_at': startsAt?.toUtc().toIso8601String(),
    'ride_style': style.name,
    'latitude': point?.latitude,
    'longitude': point?.longitude,
  };
  factory GroupMeetPlan.fromRow(Map raw) => GroupMeetPlan(
    label: raw['label'] is String ? raw['label'] as String : '',
    startsAt: DateTime.tryParse(raw['starts_at']?.toString() ?? ''),
    style:
        GroupRideStyle.values
            .where((s) => s.name == raw['ride_style'])
            .firstOrNull ??
        GroupRideStyle.relaxed,
    point: groupPoint(raw['latitude'], raw['longitude']),
    departedAt: DateTime.tryParse(raw['departed_at']?.toString() ?? ''),
  );
}

class GroupSignal {
  const GroupSignal({
    required this.id,
    required this.authorId,
    required this.kind,
    required this.createdAt,
    required this.expiresAt,
    this.point,
    this.responses = const {},
    this.note = '',
  });
  final String id, authorId;
  final GroupSignalKind kind;
  final DateTime createdAt, expiresAt;
  final LatLng? point;
  final Map<String, String> responses;
  final String note;
  bool activeAt(DateTime now) => expiresAt.isAfter(now);
  static GroupSignal? tryParse(
    Object? value, {
    Duration clockOffset = Duration.zero,
  }) {
    if (value is! Map ||
        value['id'] is! String ||
        value['author_id'] is! String) {
      return null;
    }
    final kind = GroupSignalKind.values
        .where((k) => k.name == value['kind'])
        .firstOrNull;
    final created = DateTime.tryParse(value['created_at']?.toString() ?? '');
    final expires = DateTime.tryParse(value['expires_at']?.toString() ?? '');
    if (kind == null ||
        created == null ||
        expires == null ||
        !expires.isAfter(created)) {
      return null;
    }
    final responses = <String, String>{};
    if (value['responses'] is List) {
      for (final row in value['responses'] as List) {
        if (row is Map &&
            row['user_id'] is String &&
            ['seen', 'coming'].contains(row['response'])) {
          responses[row['user_id'] as String] = row['response'] as String;
        }
      }
    }
    return GroupSignal(
      id: value['id'],
      authorId: value['author_id'],
      kind: kind,
      createdAt: created.add(clockOffset),
      expiresAt: expires.add(clockOffset),
      point: groupPoint(value['latitude'], value['longitude']),
      responses: Map.unmodifiable(responses),
      note: value['note'] is String && (value['note'] as String).length <= 120
          ? value['note'] as String
          : '',
    );
  }
}

class GroupCoordination {
  const GroupCoordination({
    this.plan = const GroupMeetPlan(),
    this.readiness = const {},
    this.signals = const [],
  });
  final GroupMeetPlan plan;
  final Map<String, GroupReadiness> readiness;
  final List<GroupSignal> signals;
  List<GroupSignal> activeSignals(DateTime now) =>
      signals.where((s) => s.activeAt(now)).toList();
  factory GroupCoordination.fromRow(
    Object? raw, {
    Duration clockOffset = Duration.zero,
  }) {
    if (raw is! Map) return const GroupCoordination();
    final readiness = <String, GroupReadiness>{};
    if (raw['readiness'] is List) {
      for (final row in raw['readiness'] as List) {
        if (row is Map && row['user_id'] is String) {
          readiness[row['user_id']] =
              GroupReadiness.values
                  .where((s) => s.name == row['state'])
                  .firstOrNull ??
              GroupReadiness.waiting;
        }
      }
    }
    return GroupCoordination(
      plan: raw['settings'] is Map
          ? GroupMeetPlan.fromRow(raw['settings'])
          : const GroupMeetPlan(),
      readiness: Map.unmodifiable(readiness),
      signals: List.unmodifiable([
        if (raw['signals'] is List)
          for (final row in raw['signals'] as List)
            if (GroupSignal.tryParse(row, clockOffset: clockOffset)
                case final GroupSignal signal)
              signal,
      ]),
    );
  }
}

/// Retains a stable request ID only for a short, explicitly retried intent.
class GroupPendingIntent {
  const GroupPendingIntent({
    required this.id,
    required this.payload,
    required this.createdAt,
  });
  final String id;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  bool reusableAt(DateTime now) =>
      now.difference(createdAt) >= Duration.zero &&
      now.difference(createdAt) < const Duration(seconds: 30);
}
