import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:pulsepath/services/compass_service.dart';
import 'package:pulsepath/services/smooth_map_heading.dart';

void main() {
  test('A 90 degree phone turn follows its top edge, not camera direction', () {
    final service = CompassService(
      minAlpha: 1,
      maxAlpha: 1,
      minPublishInterval: Duration.zero,
    );
    service.applyCompassEventForTesting(CompassEvent.fromList([0, 180, 1]));
    expect(service.heading, 0);
    service.applyCompassEventForTesting(CompassEvent.fromList([90, 180, 1]));
    expect(service.heading, 90);
    expect(service.hasValidHeading, isTrue);
    service.dispose();
  });

  test('GPS publishes direction even without compass events', () {
    final service = CompassService();
    service.updateGpsBearing(90);
    expect(service.heading, 90);
    expect(service.hasValidHeading, isTrue);
    service.updateGpsBearing(0);
    expect(service.heading, 0);
    service.updateGpsBearing(double.nan);
    expect(service.heading, 0);
    service.dispose();
  });

  test('Heading crosses north by the shortest path and converges', () {
    var angle = 359.0;
    angle = SmoothMapHeading.step(angle, 1, 0.016);
    expect(angle, greaterThan(359));
    for (var i = 0; i < 100; i++) {
      angle = SmoothMapHeading.step(angle, 1, 0.016);
    }
    expect(CompassService.shortestDelta(angle, 1).abs(), lessThan(0.001));
    expect(SmoothMapHeading.step(1, 359, 0.016), lessThan(1));
  });

  test('Damping is independent of frame rate', () {
    var fast = 0.0;
    var slow = 0.0;
    for (var i = 0; i < 60; i++) {
      fast = SmoothMapHeading.step(fast, 90, 1 / 60);
    }
    for (var i = 0; i < 30; i++) {
      slow = SmoothMapHeading.step(slow, 90, 1 / 30);
    }
    expect(fast, closeTo(slow, 0.00001));
  });
}
