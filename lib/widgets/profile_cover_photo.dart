import 'package:flutter/material.dart';

import '../models/profile_cover_crop.dart';

/// The editor and every profile render exactly the same normalized placement.
class ProfileCoverPhoto extends StatefulWidget {
  const ProfileCoverPhoto({
    super.key,
    required this.image,
    required this.crop,
    this.onSize,
  });
  static const aspectRatio = 3.0;
  final ImageProvider image;
  final ProfileCoverCrop crop;
  final ValueChanged<Size>? onSize;
  @override
  State<ProfileCoverPhoto> createState() => _ProfileCoverPhotoState();
}

class _ProfileCoverPhotoState extends State<ProfileCoverPhoto> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _size;
  bool _failed = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(ProfileCoverPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _resolve();
  }

  void _resolve() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _failed = false;
    _size = null;
    _stream = widget.image.resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener(
      (info, _) {
        final size = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        info.dispose();
        if (!mounted) return;
        setState(() => _size = size);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onSize?.call(size);
        });
      },
      onError: (Object error, StackTrace? stack) {
        if (mounted) setState(() => _failed = true);
      },
    );
    _stream!.addListener(_listener!);
  }

  @override
  void dispose() {
    if (_listener != null) _stream?.removeListener(_listener!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return const Center(child: Icon(Icons.broken_image_outlined));
    if (_size == null)
      return const Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final g = widget.crop.geometry(
            Size(constraints.maxWidth, constraints.maxHeight),
            _size!,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                left: g.offset.dx,
                top: g.offset.dy,
                width: g.size.width,
                height: g.size.height,
                child: Image(
                  image: widget.image,
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) =>
                      const Center(child: Icon(Icons.broken_image_outlined)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
