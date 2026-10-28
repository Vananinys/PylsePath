import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/video_metadata.dart';
import '../services/video_preview_service.dart';
import 'chat_photo.dart';

class VideoPoster extends StatefulWidget {
  const VideoPoster({
    super.key,
    this.localSource,
    this.posterSource,
    this.metadata,
    this.onTap,
    this.small = false,
    this.onRetry,
  });
  final String? localSource, posterSource;
  final VideoMetadata? metadata;
  final VoidCallback? onTap;
  final Future<void> Function()? onRetry;
  final bool small;
  @override
  State<VideoPoster> createState() => _VideoPosterState();
}

class _VideoPosterState extends State<VideoPoster> {
  Future<VideoPreview>? _preview;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(VideoPoster old) {
    super.didUpdateWidget(old);
    if (old.localSource != widget.localSource) _load();
  }

  void _load() {
    final source = widget.localSource;
    _preview =
        source != null &&
            !source.startsWith('http') &&
            !source.startsWith('chat:')
        ? VideoPreviewService.inspect(source)
        : null;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<VideoPreview>(
    future: _preview,
    builder: (context, snapshot) {
      final metadata = widget.metadata ?? snapshot.data?.metadata;
      final Uint8List? bytes = snapshot.data?.poster;
      final poster = widget.posterSource;
      return Semantics(
        label: 'Видео${metadata == null ? '' : ', ${metadata.durationLabel}'}',
        button: widget.onTap != null,
        child: GestureDetector(
          onTap: widget.onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: widget.small
                  ? 1
                  : (metadata?.aspectRatio ?? 16 / 9).clamp(.65, 1.9),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xff263238), Color(0xff101820)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),
                  if (poster != null)
                    ChatPhoto(
                      source: poster,
                      onRetry: widget.onRetry ?? () async {},
                      fullScreen: false,
                    )
                  else if (bytes != null)
                    Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox(),
                    ),
                  Center(
                    child: Icon(
                      Icons.play_circle_fill,
                      color: Colors.white,
                      size: widget.small ? 26 : 56,
                    ),
                  ),
                  if (!widget.small)
                    Positioned(
                      left: 8,
                      top: 8,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          child: Text(
                            metadata != null && metadata.durationMs > 0
                                ? metadata.durationLabel
                                : 'Видео',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!widget.small &&
                      metadata != null &&
                      metadata.sizeBytes > 0)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Text(
                        metadata.sizeLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          shadows: [Shadow(blurRadius: 4)],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
