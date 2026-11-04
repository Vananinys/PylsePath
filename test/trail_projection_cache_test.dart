import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/utils/trail_projection_cache.dart';
import 'package:pulsepath/models/workout_details.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/data/workout_draft_store.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  List<List<LatLng>> freeze(List<List<LatLng>> values) =>
      List.unmodifiable(values.map((s) => List<LatLng>.unmodifiable(s)));
  const a = LatLng(55, 83), b = LatLng(55.001, 83), c = LatLng(55.002, 83);
  test(
    'Append projects only new points and preserves old painter geometry',
    () async {
      final cache = TrailProjectionCache();
      var calls = 0;
      Offset project(LatLng p) {
        calls++;
        return Offset(p.latitude, p.longitude);
      }

      final first = freeze([
        [a, b],
      ]);
      final old = cache.update(first, project, immutable: true);
      for (var i = 0; i < 100; i++) {
        expect(
          identical(cache.update(first, project, immutable: true), old),
          isTrue,
        );
      }
      expect(calls, 2);
      final appended = cache.update(
        freeze([
          [a, b, c],
        ]),
        project,
        immutable: true,
      );
      expect(calls, 3);
      expect(old.single, hasLength(2));
      expect(appended.single, hasLength(3));
      expect(() => appended.single.clear(), throwsUnsupportedError);
    },
  );
  test(
    'Mutable input, gaps, shortening and reset match a fresh projection',
    () {
      final cache = TrailProjectionCache();
      Offset project(LatLng p) => Offset(p.latitude, p.longitude);
      final input = <List<LatLng>>[
        [a, b],
        [c],
      ];
      void check() => expect(cache.update(input, project), [
        for (final s in input) [for (final p in s) project(p)],
      ]);
      check();
      input.first[1] = c;
      check();
      input.first.removeLast();
      check();
      input.add([a, c]);
      check();
      input.removeAt(0);
      check();
      cache.clear();
      check();
      input.clear();
      check();
    },
  );
  test(
    'Recorded snapshots are immutable and reset for an equally sized draft',
    () async {
      SharedPreferences.setMockInitialValues({});
      WorkoutHistoryRepository.resetInstancesForTesting();
      MapNavigationController make(
        List<LatLng> points, [
        MapNavigationController? existing,
      ]) {
        final controller =
            existing ?? MapNavigationController(ownerResolver: () => 'owner');
        controller.restoreInterruptedWorkout(
          WorkoutDraft(
            ownerId: 'owner',
            localId: 'ride',
            startedAt: DateTime.now(),
            activeMilliseconds: 1000,
            distanceMeters: 10,
            elevationGainMeters: 0,
            activity: ActivityType.cycling,
            path: points,
            details: const WorkoutDetails(segmentStarts: [1]),
          ),
        );
        return controller;
      }

      final controller = make([a, b, c]);
      final segments = controller.recordedSegments;
      expect(segments, WorkoutDetails.splitTrack([a, b, c], [1]));
      expect(identical(controller.recordedSegments, segments), isTrue);
      expect(() => segments.first.clear(), throwsUnsupportedError);
      await controller.discardWorkout();
      expect(controller.recordedSegments, isEmpty);
      final replacement = make([c, b, a], controller);
      expect(
        replacement.recordedSegments,
        WorkoutDetails.splitTrack([c, b, a], [1]),
      );
      replacement.dispose();
    },
  );
  test('5k/20k/50k projections: equivalence and informational timings', () {
    final camera = MapCamera.initialCamera(const MapOptions());
    Offset project(LatLng p) {
      final q = camera.project(p, 16);
      return Offset(q.x, q.y);
    }

    for (final count in [5000, 20000, 50000]) {
      final points = [
        for (var i = 0; i < count; i++) LatLng(55 + i * .000001, 83),
      ];
      final cache = TrailProjectionCache();
      cache.update(freeze([points]), project, immutable: true);
      final next = freeze([
        [...points, c],
      ]);
      final expected = [for (final p in next.single) project(p)];
      final oldTimes = <int>[], newTimes = <int>[];
      for (var run = 0; run < 18; run++) {
        cache.clear();
        cache.update(freeze([points]), project, immutable: true);
        final baselineWatch = Stopwatch()..start();
        final fresh = [for (final p in next.single) project(p)];
        baselineWatch.stop();
        final watch = Stopwatch()..start();
        final result = cache.update(next, project, immutable: true);
        watch.stop();
        expect(result.single, fresh);
        if (run >= 3) {
          oldTimes.add(baselineWatch.elapsedMicroseconds);
          newTimes.add(watch.elapsedMicroseconds);
        }
      }
      oldTimes.sort();
      newTimes.sort();
      final actual = cache.update(next, project, immutable: true);
      expect(actual.single, expected);
      // Informational JIT timing; equivalence and call-count tests are the gates.
      // ignore: avoid_print
      print(
        'points=$count full_median_us=${oldTimes[7]} '
        'incremental_median_us=${newTimes[7]} projected_new=1',
      );
    }
  });
}
