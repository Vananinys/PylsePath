import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class MapStickerEffect {
  const MapStickerEffect({
    required this.id,
    required this.point,
    required this.emoji,
    required this.origin,
    this.rain = false,
  });
  final String id;
  final LatLng point;
  final String emoji;
  final Offset origin;
  final bool rain;
}

class MapStickerFlightOverlay extends StatefulWidget {
  const MapStickerFlightOverlay({
    super.key,
    required this.effects,
    required this.mapController,
    this.onEffectCompleted,
  });
  final ValueListenable<List<MapStickerEffect>> effects;
  final MapController mapController;
  final ValueChanged<String>? onEffectCompleted;
  @override
  State<MapStickerFlightOverlay> createState() =>
      _MapStickerFlightOverlayState();
}

class _MapStickerFlightOverlayState extends State<MapStickerFlightOverlay> {
  final _surfaceKey = GlobalKey();
  @override
  void dispose() {
    final ids = widget.effects.value.map((effect) => effect.id).toList();
    final complete = widget.onEffectCompleted;
    // Hidden overlays must not replay unfinished effects when shown again.
    if (complete != null && ids.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final id in ids) {
          complete(id);
        }
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SizedBox.expand(
      key: _surfaceKey,
      child: StreamBuilder<MapEvent>(
        stream: widget.mapController.mapEventStream,
        builder: (context, _) => ValueListenableBuilder<List<MapStickerEffect>>(
          valueListenable: widget.effects,
          builder: (context, effects, _) => Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (final effect in effects)
                Builder(
                  key: ValueKey('sticker-flight:${effect.id}'),
                  builder: (context) {
                    final box =
                        _surfaceKey.currentContext?.findRenderObject()
                            as RenderBox?;
                    final from =
                        box?.globalToLocal(effect.origin) ?? effect.origin;
                    final target = widget.mapController.camera
                        .latLngToScreenPoint(effect.point);
                    return StickerFlight(
                      key: ValueKey(effect.id),
                      emoji: effect.emoji,
                      from: from,
                      to: Offset(target.x, target.y) - const Offset(0, 22),
                      rain: effect.rain,
                      onCompleted: () =>
                          widget.onEffectCompleted?.call(effect.id),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// An original approximation: chip-to-avatar flight, elastic landing and emoji-specific satellites.
class StickerFlight extends StatelessWidget {
  const StickerFlight({
    super.key,
    required this.emoji,
    required this.from,
    required this.to,
    this.rain = false,
    this.onCompleted,
  });
  final String emoji;
  final Offset from;
  final Offset to;
  final bool rain;
  final VoidCallback? onCompleted;

  static Offset position(
    Offset from,
    Offset to,
    double t, {
    double bend = 70,
  }) =>
      Offset.lerp(from, to, t)! +
      Offset(math.sin(math.pi * t) * bend * .25, -math.sin(math.pi * t) * bend);

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: reduced ? 450 : 2300),
      onEnd: onCompleted,
      builder: (context, t, _) {
        final count = reduced
            ? 1
            : rain
            ? 14
            : 1;
        final children = <Widget>[];
        for (var i = 0; i < count; i++) {
          final local = ((t - i * .018) / (1 - i * .018)).clamp(0.0, 1.0);
          final travel = Curves.easeInOutCubic.transform(
            (local / .46).clamp(0.0, 1.0),
          );
          final after = ((local - .46) / .54).clamp(0.0, 1.0);
          final angle = i * 2.39996;
          final landing =
              to +
              (rain
                  ? Offset(math.cos(angle) * 48, math.sin(angle) * 32)
                  : Offset.zero);
          final point = reduced
              ? to
              : position(from, landing, travel, bend: 75 + i * 6) +
                    Offset(
                      math.sin(after * math.pi * 2) * 5,
                      -after * after * 70,
                    );
          final opacity =
              (local < .04
                      ? local / .04
                      : local > .8
                      ? (1 - local) / .2
                      : 1.0)
                  .clamp(0.0, 1.0);
          final scale = reduced
              ? 1.0
              : .6 +
                    .5 *
                        math.sin(
                          math.min(1, travel + after * .25) * math.pi / 2,
                        ) +
                    math.sin(after * math.pi * 3) * .12 * (1 - after);
          children.add(
            Positioned(
              left: point.dx - 24,
              top: point.dy - 24,
              child: Opacity(
                opacity: opacity,
                child: Transform.rotate(
                  angle: reduced
                      ? 0
                      : math.sin(travel * math.pi * 2) * .2 +
                            math.sin(after * math.pi * 4) * .12,
                  child: Transform.scale(
                    scale: scale,
                    child: Text(
                      emoji,
                      style: const TextStyle(
                        fontSize: 46,
                        shadows: [Shadow(color: Colors.black26, blurRadius: 8)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          if (!reduced && !rain && after > 0) {
            final count = emoji == '❤️' || emoji == '🔥' ? 7 : 5;
            for (var j = 0; j < count; j++) {
              final phase = ((after - j * .04) / .72).clamp(0.0, 1.0);
              final a = j * math.pi * 2 / count;
              final satellite = emoji == '❤️'
                  ? '❤️'
                  : emoji == '🔥'
                  ? '🔥'
                  : emoji == '🚀'
                  ? '✨'
                  : emoji;
              final offset = Offset(
                math.cos(a) * phase * 64,
                math.sin(a) * phase * 35 - phase * phase * 85,
              );
              children.add(
                Positioned(
                  left: to.dx + offset.dx - 12,
                  top: to.dy + offset.dy - 12,
                  child: Opacity(
                    opacity: (math.sin(phase * math.pi) * .9).clamp(0, 1),
                    child: Text(
                      satellite,
                      style: TextStyle(fontSize: 16 + (1 - phase) * 10),
                    ),
                  ),
                ),
              );
            }
          }
        }
        return Stack(clipBehavior: Clip.none, children: children);
      },
    );
  }
}
