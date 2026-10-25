import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/gps_signal.dart';

class GpsSignalIndicator extends StatelessWidget {
  const GpsSignalIndicator({
    super.key,
    required this.signal,
    this.onTap,
    this.refreshing = false,
    this.compact = false,
  });
  final ValueListenable<GpsSignal> signal;
  final VoidCallback? onTap;
  final bool refreshing;
  final bool compact;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<GpsSignal>(
    valueListenable: signal,
    builder: (context, value, _) {
      final (label, color, icon) = switch (value.quality) {
        GpsQuality.searching => (
          'GPS: поиск',
          Colors.blueGrey,
          Icons.gps_not_fixed,
        ),
        GpsQuality.good => ('GPS: хороший', Colors.green, Icons.gps_fixed),
        GpsQuality.weak => ('GPS: слабый', Colors.orange, Icons.gps_not_fixed),
        GpsQuality.lost => ('GPS: сигнал потерян', Colors.red, Icons.gps_off),
      };
      final accuracy = value.accuracy;
      final text =
          accuracy != null &&
              accuracy.isFinite &&
              accuracy >= 0 &&
              value.quality != GpsQuality.lost
          ? '$label · ±${accuracy.ceil()} м'
          : label;
      return Tooltip(
        message: onTap != null
            ? 'Обновить GPS и показать моё местоположение'
            : value.quality == GpsQuality.lost
            ? 'Нет свежих координат. Проверьте геолокацию и выйдите на открытое место.'
            : 'Оценка точности местоположения. При слабом сигнале трек может быть неточным.',
        child: Semantics(
          liveRegion: value.quality == GpsQuality.lost,
          child: Material(
            elevation: 2,
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: refreshing ? null : onTap,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (refreshing)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(icon, color: color, size: 18),
                    if (!compact || value.quality != GpsQuality.good)
                      const SizedBox(width: 6),
                    if (!compact || value.quality != GpsQuality.good)
                      Flexible(
                        child: Text(
                          refreshing ? 'GPS: обновление…' : text,
                          maxLines: 2,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
