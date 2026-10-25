import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/map_mark.dart';

/// Городские метки (micro-reports) на карте: таблица `map_marks`.
///
/// Видимость — всем вошедшим, пока `expires_at > now()` (фильтр в RLS).
/// Realtime: INSERT/DELETE приходят всем подписчикам, UPDATE меток нет.
class MapMarksService {
  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  static bool get isAvailable => _client != null;

  String? get userId => _client?.auth.currentUser?.id;

  RealtimeChannel? _channel;

  /// Активные (неистёкшие) метки в ограничивающем прямоугольнике.
  /// bbox чуть расширяется, чтобы метки у края экрана не мигали.
  Future<List<MapMark>> fetchVisible(
    double south,
    double west,
    double north,
    double east,
  ) async {
    final client = _client;
    if (client == null) return const [];
    const pad = 0.01; // ~1 км по широте
    try {
      final rows = await client
          .from('map_marks')
          .select()
          .gte('latitude', south - pad)
          .lte('latitude', north + pad)
          .gte('longitude', west - pad)
          .lte('longitude', east + pad)
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .timeout(const Duration(seconds: 12));
      return [for (final row in rows) _parse(Map<String, dynamic>.from(row))]
          .whereType<MapMark>()
          .toList();
    } catch (error) {
      debugPrint('[MapMarks] fetch failed: $error');
      return const [];
    }
  }

  /// Создаёт метку от текущего пользователя. TTL считает клиент — серверный
  /// CHECK не знает тип, а занижение TTL безопаснее завышения.
  Future<MapMark?> create(LatLng point, MarkType type, {String? note}) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return null;
    final now = DateTime.now().toUtc();
    try {
      final row = await client
          .from('map_marks')
          .insert({
            'author_id': id,
            'mark_type': type.id,
            'latitude': point.latitude,
            'longitude': point.longitude,
            if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
            'created_at': now.toIso8601String(),
            'expires_at': type.expiryFrom(now).toIso8601String(),
          })
          .select()
          .single()
          .timeout(const Duration(seconds: 15));
      return _parse(Map<String, dynamic>.from(row));
    } catch (error) {
      debugPrint('[MapMarks] create failed: $error');
      return null;
    }
  }

  /// Убирает метку. Успешно только для своей (RLS молча отфильтрует чужую).
  Future<bool> delete(String markId) async {
    final client = _client;
    if (client == null) return false;
    try {
      await client
          .from('map_marks')
          .delete()
          .eq('id', markId)
          .timeout(const Duration(seconds: 12));
      return true;
    } catch (error) {
      debugPrint('[MapMarks] delete failed: $error');
      return false;
    }
  }

  /// Подписка на появление/удаление меток в реальном времени.
  Future<void> subscribe(
    void Function(MapMark mark) onInsert,
    void Function(String markId) onDelete,
  ) async {
    final client = _client;
    if (client == null) return;
    await unsubscribe();
    try {
      _channel = client
          .channel('map_marks_feed')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'map_marks',
            callback: (payload) {
              final mark = _parse(Map<String, dynamic>.from(payload.newRecord));
              // _parse возвращает null для битых записей — их пропускаем.
              if (mark != null) onInsert(mark);
            },
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.delete,
            schema: 'public',
            table: 'map_marks',
            callback: (payload) {
              final old = payload.oldRecord;
              final id = (old['id'] ?? '').toString();
              if (id.isNotEmpty) onDelete(id);
            },
          )
          .subscribe();
    } catch (error) {
      debugPrint('[MapMarks] realtime subscribe failed: $error');
    }
  }

  Future<void> unsubscribe() async {
    final client = _client;
    final channel = _channel;
    _channel = null;
    if (client == null || channel == null) return;
    try {
      await client.removeChannel(channel);
    } catch (_) {}
  }

  /// Неизвестный mark_type (пришёл от новой версии сервера) молча пропускаем.
  MapMark? _parse(Map<String, dynamic> row) {
    try {
      return MapMark.fromRow(row);
    } catch (_) {
      return null;
    }
  }
}
