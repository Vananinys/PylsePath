import 'package:flutter/material.dart';

/// Тип городской метки (micro-report). TTL подобран под «живучесть»
/// проблемы: яму чинят неделями, ремонт длится дольше, собаки гуляют
/// у дома каждый день, а удобная парковка — разовая подсказка.
enum MarkType {
  pothole('pothole', 'Яма', '🕳️', 30, Color(0xFFE53935)),
  roadwork('roadwork', 'Ремонт дороги', '🚧', 14, Color(0xFFFB8C00)),
  dogs('dogs', 'Собаки', '🐕', 7, Color(0xFF8E24AA)),
  parking('parking', 'Парковка', '🅿️', 0.5, Color(0xFF1E88E5));

  final String id;
  final String label;
  final String emoji;
  final double ttlDays;
  final Color color;

  const MarkType(this.id, this.label, this.emoji, this.ttlDays, this.color);

  static MarkType? fromId(String? id) {
    for (final type in MarkType.values) {
      if (type.id == id) return type;
    }
    return null;
  }

  /// Момент истечения метки этого типа от [from].
  DateTime expiryFrom(DateTime from) =>
      from.add(Duration(milliseconds: (ttlDays * 24 * 60 * 60 * 1000).round()));
}

/// Городская метка на карте: «здесь яма / собаки / парковка / ремонт».
class MapMark {
  final String id;
  final String authorId;
  final MarkType type;
  final double latitude;
  final double longitude;
  final String? note;
  final DateTime createdAt;
  final DateTime expiresAt;

  const MapMark({
    required this.id,
    required this.authorId,
    required this.type,
    required this.latitude,
    required this.longitude,
    this.note,
    required this.createdAt,
    required this.expiresAt,
  });

  /// Доля оставшейся жизни метки в [0, 1] — для яркости пина.
  double get freshness {
    final total = expiresAt.difference(createdAt).inMilliseconds;
    if (total <= 0) return 0;
    final left = expiresAt.difference(DateTime.now()).inMilliseconds;
    return left <= 0 ? 0 : (left / total).clamp(0.0, 1.0);
  }

  factory MapMark.fromRow(Map<String, dynamic> row) {
    final type = MarkType.fromId(row['mark_type'] as String?);
    if (type == null) {
      throw const FormatException('Unknown mark_type');
    }
    return MapMark(
      id: row['id'] as String,
      authorId: row['author_id'] as String,
      type: type,
      latitude: (row['latitude'] as num).toDouble(),
      longitude: (row['longitude'] as num).toDouble(),
      note: row['note'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
      expiresAt: DateTime.parse(row['expires_at'] as String),
    );
  }
}
