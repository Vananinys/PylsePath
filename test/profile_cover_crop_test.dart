import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/models/profile_cover_crop.dart';

void main() {
  test(
    'portrait crop fills the banner and matches on differently sized profiles',
    () {
      const crop = ProfileCoverCrop(x: .15, y: .72, zoom: 2.3);
      const source = Size(1000, 2000);
      final small = crop.geometry(const Size(300, 100), source);
      final large = crop.geometry(const Size(600, 200), source);
      expect(small.offset.dx, lessThanOrEqualTo(0));
      expect(small.offset.dy, lessThanOrEqualTo(0));
      expect(small.offset.dx + small.size.width, greaterThanOrEqualTo(300));
      expect(small.offset.dy + small.size.height, greaterThanOrEqualTo(100));
      expect(
        large.sourcePointAt(const Offset(300, 100)),
        small.sourcePointAt(const Offset(150, 50)),
      );
    },
  );
  test('zoom keeps the source point under the fingers', () {
    const crop = ProfileCoverCrop(zoom: 2);
    const frame = Size(300, 100),
        source = Size(1000, 1000),
        focal = Offset(150, 50);
    final point = crop.geometry(frame, source).sourcePointAt(focal);
    final zoomed = crop.move(
      frame: frame,
      source: source,
      sourcePoint: point,
      focalPoint: focal,
      newZoom: 3,
    );
    final actual = zoomed.geometry(frame, source).sourcePointAt(focal);
    expect(actual.dx, closeTo(point.dx, .000001));
    expect(actual.dy, closeTo(point.dy, .000001));
  });
  test(
    'extreme dragging and untrusted cached data cannot expose blank edges',
    () {
      final crop = const ProfileCoverCrop().move(
        frame: const Size(300, 100),
        source: const Size(1000, 2000),
        sourcePoint: const Offset(.5, .5),
        focalPoint: const Offset(9000, -9000),
        newZoom: 50,
      );
      expect(crop.x, inInclusiveRange(0, 1));
      expect(crop.y, inInclusiveRange(0, 1));
      expect(crop.zoom, 4);
      final restored = ProfileCoverCrop.fromJson({
        'x': double.nan,
        'y': -20,
        'zoom': 'bad',
      });
      expect(restored.x, .5);
      expect(restored.y, 0);
      expect(restored.zoom, 1);
      expect(ProfileCoverCrop.fromJson(crop.toJson()), crop);
    },
  );
}
