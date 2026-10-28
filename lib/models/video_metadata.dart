import 'dart:typed_data';

class VideoMetadata {
  const VideoMetadata({
    this.width = 0,
    this.height = 0,
    this.durationMs = 0,
    this.sizeBytes = 0,
  });
  final int width, height, durationMs, sizeBytes;
  double get aspectRatio => width > 0 && height > 0 ? width / height : 16 / 9;
  String get durationLabel => videoTime(Duration(milliseconds: durationMs));
  String get sizeLabel => sizeBytes <= 0
      ? ''
      : sizeBytes < 1024 * 1024
      ? '${(sizeBytes / 1024).ceil()} КБ'
      : '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'duration_ms': durationMs,
    'size_bytes': sizeBytes,
  };
  static VideoMetadata? tryParse(Object? raw) {
    if (raw is! Map) return null;
    for (final key in ['width', 'height', 'duration_ms', 'size_bytes']) {
      if (raw[key] is! int || (raw[key] as int) < 0) return null;
    }
    if (raw['width'] > 16384 ||
        raw['height'] > 16384 ||
        raw['duration_ms'] > 86400000 ||
        raw['size_bytes'] > 52428800) {
      return null;
    }
    return VideoMetadata(
      width: raw['width'],
      height: raw['height'],
      durationMs: raw['duration_ms'],
      sizeBytes: raw['size_bytes'],
    );
  }
}

class VideoPreview {
  const VideoPreview({required this.metadata, this.poster});
  final VideoMetadata metadata;
  final Uint8List? poster;
}

String videoTime(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 86400);
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
}
