import 'dart:math' as math;
import 'dart:ui';

/// Placement relative to the image's available travel, independent of pixels.
class ProfileCoverCrop {
  const ProfileCoverCrop({this.x = .5, this.y = .5, this.zoom = 1});
  final double x, y, zoom;

  factory ProfileCoverCrop.fromJson(dynamic value) {
    if (value is! Map) return const ProfileCoverCrop();
    double read(String key, double fallback, double min, double max) {
      final v = value[key];
      return v is num && v.isFinite ? v.toDouble().clamp(min, max) : fallback;
    }

    return ProfileCoverCrop(
      x: read('x', .5, 0, 1),
      y: read('y', .5, 0, 1),
      zoom: read('zoom', 1, 1, 4),
    );
  }

  Map<String, double> toJson() => {'x': x, 'y': y, 'zoom': zoom};

  CoverGeometry geometry(Size frame, Size source) {
    final scale =
        math.max(frame.width / source.width, frame.height / source.height) *
        zoom;
    final size = Size(source.width * scale, source.height * scale);
    return CoverGeometry(
      size,
      Offset(
        -(size.width - frame.width).clamp(0, double.infinity) * x,
        -(size.height - frame.height).clamp(0, double.infinity) * y,
      ),
    );
  }

  /// Keeps the source point underneath the fingers while panning and zooming.
  ProfileCoverCrop move({
    required Size frame,
    required Size source,
    required Offset sourcePoint,
    required Offset focalPoint,
    required double newZoom,
  }) {
    final z = newZoom.clamp(1.0, 4.0);
    final size = ProfileCoverCrop(zoom: z).geometry(frame, source).size;
    final travelX = (size.width - frame.width).clamp(0.0, double.infinity);
    final travelY = (size.height - frame.height).clamp(0.0, double.infinity);
    return ProfileCoverCrop(
      x: travelX < .001
          ? .5
          : ((sourcePoint.dx * size.width - focalPoint.dx) / travelX).clamp(
              0.0,
              1.0,
            ),
      y: travelY < .001
          ? .5
          : ((sourcePoint.dy * size.height - focalPoint.dy) / travelY).clamp(
              0.0,
              1.0,
            ),
      zoom: z,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProfileCoverCrop &&
      other.x == x &&
      other.y == y &&
      other.zoom == zoom;
  @override
  int get hashCode => Object.hash(x, y, zoom);
}

class CoverGeometry {
  const CoverGeometry(this.size, this.offset);
  final Size size;
  final Offset offset;
  Offset sourcePointAt(Offset point) => Offset(
    (point.dx - offset.dx) / size.width,
    (point.dy - offset.dy) / size.height,
  );
}
