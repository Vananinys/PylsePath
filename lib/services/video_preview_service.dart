import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../models/video_metadata.dart';

/// Local poster extraction is bounded and serialized; no remote-video prefetch.
class VideoPreviewService {
  static final Map<String, Future<VideoPreview>> _cache = {};
  static Future<void> _tail = Future.value();
  static Future<VideoPreview> inspect(String path) async {
    int length = 0;
    String stamp = '';
    try {
      final file = XFile(path);
      length = await file.length();
      stamp = (await file.lastModified()).toIso8601String();
    } catch (_) {
      return const VideoPreview(metadata: VideoMetadata());
    }
    if (length <= 0 || length > 50 * 1024 * 1024) {
      return const VideoPreview(metadata: VideoMetadata());
    }
    final key = '$path|$length|$stamp';
    final cached = _cache[key];
    if (cached != null) return cached;
    final future = _tail
        .catchError((Object _) {})
        .then((_) => _extract(path, length));
    _tail = future.then<void>((_) {});
    if (_cache.length >= 32) _cache.remove(_cache.keys.first);
    _cache[key] = future;
    return future;
  }

  static Future<VideoPreview> _extract(String path, int size) async {
    final fallback = VideoPreview(metadata: VideoMetadata(sizeBytes: size));
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return fallback;
    }
    try {
      final raw = await const MethodChannel('pulsepath/video_preview')
          .invokeMapMethod<String, dynamic>('inspect', {'path': path})
          .timeout(const Duration(seconds: 12));
      if (raw == null) return fallback;
      final metadata =
          VideoMetadata.tryParse({...raw, 'size_bytes': size}) ??
          fallback.metadata;
      final poster = raw['poster'];
      return VideoPreview(
        metadata: metadata,
        poster: poster is Uint8List && poster.length <= 512 * 1024
            ? poster
            : null,
      );
    } catch (_) {
      return fallback;
    }
  }

  @visibleForTesting
  static void clearCacheForTesting() {
    _cache.clear();
    _tail = Future.value();
  }
}
