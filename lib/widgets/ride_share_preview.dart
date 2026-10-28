import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

import 'ride_share_card.dart';

/// The export boundary receives only summary metrics, never the ride or profile.
class RideSharePreview extends StatefulWidget {
  const RideSharePreview({
    super.key,
    required this.activityType,
    required this.distanceMeters,
    required this.durationSeconds,
    this.elevationGainMeters,
    this.onShare,
  });

  final String activityType;
  final double distanceMeters;
  final double durationSeconds;
  final double? elevationGainMeters;
  final Future<void> Function(Uint8List png, Rect origin)? onShare;

  @override
  State<RideSharePreview> createState() => _RideSharePreviewState();
}

class _RideSharePreviewState extends State<RideSharePreview> {
  final _imageKey = GlobalKey();
  bool _busy = false;

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final boundary = _imageKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        throw StateError('Card is not painted yet');
      }
      if (boundary.debugNeedsPaint) {
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted || boundary.debugNeedsPaint) return;
      final origin = boundary.localToGlobal(Offset.zero) & boundary.size;
      final image = await boundary.toImage(pixelRatio: 3);
      late final Uint8List png;
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('PNG encoding failed');
        png = bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        );
      } finally {
        image.dispose();
      }
      if (!mounted) return;
      final onShare = widget.onShare;
      if (onShare != null) {
        await onShare(png, origin);
      } else {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile.fromData(png, mimeType: 'image/png')],
            fileNameOverrides: ['pulsepath-ride.png'],
            sharePositionOrigin: origin,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось подготовить карточку. Попробуйте ещё раз.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Карточка заезда',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'В картинке только показатели заезда: без маршрута, координат и личных отметок.',
            ),
            const SizedBox(height: 12),
            RepaintBoundary(
              key: _imageKey,
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: RideShareCard(
                  activityType: widget.activityType,
                  distanceMeters: widget.distanceMeters,
                  durationSeconds: widget.durationSeconds,
                  elevationGainMeters: widget.elevationGainMeters,
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _share,
              icon: const Icon(Icons.ios_share),
              label: Text(_busy ? 'Подготовка…' : 'Поделиться картинкой'),
            ),
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              child: const Text('Закрыть'),
            ),
          ],
        ),
      ),
    ),
  );
}
