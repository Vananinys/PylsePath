import 'package:flutter/material.dart';

/// Итоговая карточка заезда для шаринга.
///
/// Только переданные числа: без сети, Supabase, локального хранилища,
/// координат, маршрута и личных данных.
class RideShareCard extends StatelessWidget {
  const RideShareCard({
    super.key,
    required this.activityType,
    required this.distanceMeters,
    required this.durationSeconds,
    this.elevationGainMeters,
  });

  final String activityType;

  /// Дистанция в метрах.
  final double distanceMeters;

  /// Длительность в секундах.
  final double durationSeconds;

  /// Набор высоты в метрах; null — метрика не показывается.
  final double? elevationGainMeters;

  static const String _dash = '—';

  bool _isValid(double v) => v.isFinite && v >= 0;

  String _formatDistance(double meters) {
    if (!_isValid(meters)) return _dash;
    if (meters < 1000) return '${meters.toStringAsFixed(0)} м';
    return '${(meters / 1000).toStringAsFixed(2)} км';
  }

  String _formatDuration(double seconds) {
    if (!_isValid(seconds)) return _dash;
    final int total = seconds.floor();
    final int h = total ~/ 3600;
    final int m = (total % 3600) ~/ 60;
    final int s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  String _formatElevation(double? meters) {
    if (meters == null || !_isValid(meters)) return _dash;
    return '${meters.toStringAsFixed(0)} м';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final metrics = <_MetricData>[
      _MetricData(_formatDistance(distanceMeters), 'Дистанция'),
      _MetricData(_formatDuration(durationSeconds), 'Длительность'),
      if (elevationGainMeters != null)
        _MetricData(_formatElevation(elevationGainMeters), 'Набор высоты'),
    ];

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.route_outlined,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'PulsePath',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              activityType,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            // Wrap вместо Row: карточка не переполняется на узкой ширине
            // и при увеличенном масштабе текста.
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                for (final metric in metrics)
                  _MetricValue(value: metric.value, label: metric.label),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricData {
  const _MetricData(this.value, this.label);
  final String value;
  final String label;
}

class _MetricValue extends StatelessWidget {
  const _MetricValue({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
