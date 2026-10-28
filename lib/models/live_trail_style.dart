import '../data/trail_appearance.dart';

/// An owner's cosmetic choice, never coordinates or a recorded route.
class LiveTrailStyle {
  const LiveTrailStyle({
    this.style = TrailStyle.automatic,
    this.colorIndex = 0,
    this.size = 10,
    this.spacing = 28,
    this.opacity = .85,
    this.enabled = true,
  });
  final TrailStyle style;
  final int colorIndex;
  final double size, spacing, opacity;
  final bool enabled;

  factory LiveTrailStyle.fromRow(Map<String, dynamic> row) {
    if (row['version'] != 1) return const LiveTrailStyle();
    double number(String key, double fallback, double min, double max) {
      final value = row[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    return LiveTrailStyle(
      style:
          TrailStyle.values.where((s) => s.name == row['style']).firstOrNull ??
          TrailStyle.automatic,
      colorIndex: (row['color_index'] is int ? row['color_index'] as int : 0)
          .clamp(0, TrailAppearance.colors.length - 1),
      size: number('marker_size', 10, 6, 20),
      spacing: number('spacing', 28, 16, 64),
      opacity: number('opacity', .85, .25, 1),
      enabled: row['enabled'] != false,
    );
  }
  Map<String, Object> toRow() => {
    'version': 1,
    'style': style.name,
    'color_index': colorIndex,
    'marker_size': size,
    'spacing': spacing,
    'opacity': opacity,
    'enabled': enabled,
  };
  LiveTrailStyle copyWith({
    TrailStyle? style,
    int? colorIndex,
    double? size,
    double? spacing,
    double? opacity,
    bool? enabled,
  }) => LiveTrailStyle.fromRow({
    ...toRow(),
    if (style != null) 'style': style.name,
    if (colorIndex != null) 'color_index': colorIndex,
    if (size != null) 'marker_size': size,
    if (spacing != null) 'spacing': spacing,
    if (opacity != null) 'opacity': opacity,
    if (enabled != null) 'enabled': enabled,
  });
}
