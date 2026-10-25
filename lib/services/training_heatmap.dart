import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/saved_route.dart';
import 'heatmap_explorer.dart';

class HeatCell {
  const HeatCell(this.point, this.intensity);
  final LatLng point;
  final int intensity;
}

class TrainingHeatmap {
  static Future<List<HeatCell>> filteredPublicCells(
    double south,
    double west,
    double north,
    double east,
    HeatmapFilter filter,
  ) async {
    final rows = await _client
        .rpc(
          'public_heatmap_filtered',
          params: {
            'p_south': south,
            'p_west': west,
            'p_north': north,
            'p_east': east,
            'p_sport': filter.sport.name,
            'p_start': filter.start?.toUtc().toIso8601String(),
            'p_end': filter.end == null
                ? null
                : DateTime(
                    filter.end!.year,
                    filter.end!.month,
                    filter.end!.day + 1,
                  ).toUtc().toIso8601String(),
          },
        )
        .timeout(const Duration(seconds: 15));
    return (rows as List)
        .map(
          (r) => HeatCell(
            LatLng((r['lat'] as num).toDouble(), (r['lon'] as num).toDouble()),
            (r['intensity'] as num).toInt(),
          ),
        )
        .toList();
  }

  /// Count a cell once per workout. Never connect paused GPS segments.
  static List<HeatCell> personal(List<SavedRoute> rides) {
    final counts = <(int, int), int>{};
    const distance = Distance();
    for (final ride in rides) {
      final visited = <(int, int)>{};
      final breaks = ride.workoutDetails.segmentStarts.toSet();
      void add(LatLng p) {
        if (!p.latitude.isFinite ||
            !p.longitude.isFinite ||
            p.latitude.abs() > 85 ||
            p.longitude.abs() > 180)
          return;
        visited.add((
          (p.latitude / 0.001).floor(),
          (p.longitude / 0.001).floor(),
        ));
      }

      final points = ride.routePoints;
      for (var i = 0; i < points.length; i++) {
        add(points[i]);
        if (i == 0 || breaks.contains(i)) continue;
        final a = points[i - 1], b = points[i];
        final meters = distance(a, b);
        if (!meters.isFinite || meters > 500) continue;
        final steps = (meters / 40).ceil();
        for (var k = 1; k < steps; k++) {
          add(
            LatLng(
              a.latitude + (b.latitude - a.latitude) * k / steps,
              a.longitude + (b.longitude - a.longitude) * k / steps,
            ),
          );
        }
      }
      for (final cell in visited) {
        counts.update(cell, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return counts.entries
        .map(
          (e) => HeatCell(
            LatLng((e.key.$1 + 0.5) * 0.001, (e.key.$2 + 0.5) * 0.001),
            e.value,
          ),
        )
        .toList();
  }

  static double strength(int count) =>
      (0.25 + math.log(1 + count) / 5).clamp(0.25, 0.9);
  static SupabaseClient get _client => Supabase.instance.client;
  static Future<bool> consent() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return false;
    final row = await _client
        .from('heatmap_preferences')
        .select('enabled')
        .eq('user_id', uid)
        .maybeSingle();
    return row?['enabled'] == true;
  }

  static Future<void> setConsent(bool value) async {
    await _client
        .rpc('set_heatmap_consent', params: {'p_enabled': value})
        .timeout(const Duration(seconds: 90));
  }

  static Future<List<HeatCell>> publicCells(
    double south,
    double west,
    double north,
    double east,
  ) async {
    final rows = await _client
        .rpc(
          'public_heatmap',
          params: {
            'p_south': south,
            'p_west': west,
            'p_north': north,
            'p_east': east,
          },
        )
        .timeout(const Duration(seconds: 15));
    return (rows as List)
        .map(
          (r) => HeatCell(
            LatLng((r['lat'] as num).toDouble(), (r['lon'] as num).toDouble()),
            (r['intensity'] as num).toInt(),
          ),
        )
        .toList();
  }
}
