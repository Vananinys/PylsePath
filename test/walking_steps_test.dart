import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/models/walking_steps.dart';
import 'package:pulsepath/models/workout_details.dart';
import 'package:pulsepath/services/recording_daily_activity_service.dart';
import 'package:pulsepath/services/workout_step_tracker.dart';

class WalkingPlatform extends StepRecordingPlatform {
  WalkingPlatform({this.android = false});
  final bool android;
  List<int>? totals;
  @override
  bool get supported => android;
  @override
  Future<Map<dynamic, dynamic>> invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async => {
    'totals': totals ?? List.filled((arguments!['windows'] as List).length, 0),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DateTime now;
  setUp(() {
    now = DateTime(2026, 10, 24, 23, 59, 50);
    SharedPreferences.setMockInitialValues({
      'walking_step_device_v1': 'device-test',
    });
  });
  test('walking counts only active intervals and ignores pause movement', () {
    final tracker = WorkoutStepTracker(
      platform: WalkingPlatform(),
      now: () => now,
    )..start(foot: true);
    void sample(int count) => tracker.acceptSensor({
      'count': count,
      'at': now.millisecondsSinceEpoch,
    });
    sample(100);
    now = now.add(const Duration(seconds: 5));
    sample(110);
    expect(tracker.count, 10);
    tracker.pause();
    now = now.add(const Duration(seconds: 30));
    sample(190);
    expect(tracker.count, 10);
    tracker.resume();
    sample(190);
    now = now.add(const Duration(seconds: 5));
    sample(205);
    expect(tracker.count, 25);
    expect(tracker.snapshot!.windows.length, 2);
    tracker.dispose();
  });
  test('midnight and reboot never reset the workout or add a boot counter', () {
    final tracker = WorkoutStepTracker(
      platform: WalkingPlatform(),
      now: () => now,
    )..start(foot: true);
    tracker.acceptSensor({'count': 1000, 'at': now.millisecondsSinceEpoch});
    now = now.add(const Duration(seconds: 20));
    tracker.acceptSensor({'count': 1020, 'at': now.millisecondsSinceEpoch});
    expect(tracker.count, 20);
    now = now.add(const Duration(seconds: 1));
    tracker.acceptSensor({'count': 3, 'at': now.millisecondsSinceEpoch});
    now = now.add(const Duration(seconds: 1));
    tracker.acceptSensor({'count': 8, 'at': now.millisecondsSinceEpoch});
    expect(tracker.count, 25);
    tracker.dispose();
  });
  test('late hardware events do not move the baseline backwards', () {
    final tracker = WorkoutStepTracker(
      platform: WalkingPlatform(),
      now: () => now,
    )..start(foot: true);
    final start = now.millisecondsSinceEpoch;
    tracker.acceptSensor({'count': 100, 'at': start});
    now = now.add(const Duration(seconds: 10));
    tracker.acceptSensor({'count': 110, 'at': now.millisecondsSinceEpoch});
    tracker.acceptSensor({'count': 105, 'at': start + 5000});
    now = now.add(const Duration(seconds: 5));
    tracker.acceptSensor({'count': 115, 'at': now.millisecondsSinceEpoch});
    expect(tracker.count, 15);
    tracker.dispose();
  });
  test(
    'Google totals reconcile by maximum rather than double-counting sensors',
    () async {
      final platform = WalkingPlatform(android: true);
      final tracker = WorkoutStepTracker(platform: platform, now: () => now)
        ..start(foot: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      tracker.acceptSensor({'count': 100, 'at': now.millisecondsSinceEpoch});
      now = now.add(const Duration(seconds: 5));
      tracker.acceptSensor({'count': 110, 'at': now.millisecondsSinceEpoch});
      platform.totals = [12];
      await tracker.refresh();
      expect(tracker.count, 12);
      platform.totals = [3];
      await tracker.refresh();
      expect(tracker.count, 12);
      expect(tracker.snapshot!.device, 'device-test');
      tracker.dispose();
    },
  );
  test(
    'draft restore closes an unfinished step interval at its checkpoint',
    () {
      final tracker = WorkoutStepTracker(
        platform: WalkingPlatform(),
        now: () => now,
      )..start(foot: true);
      now = now.add(const Duration(seconds: 10));
      final saved = tracker.snapshot!.toJson();
      tracker.dispose();
      now = now.add(const Duration(hours: 2));
      final restored = WalkingSteps.fromJson(saved, restorePaused: true)!;
      expect(restored.windows.last.end, saved['observed_at']);
      final next =
          WorkoutStepTracker(platform: WalkingPlatform(), now: () => now)
            ..restore(restored)
            ..resume();
      expect(next.snapshot!.windows.length, 2);
      expect(next.snapshot!.windows.last.start, now.millisecondsSinceEpoch);
      next.dispose();
    },
  );
  test('walking steps survive workout serialization and preserve stride', () {
    final original = WorkoutDetails(
      walkingSteps: WalkingSteps(
        device: 'test',
        windows: [StepWindow(start: 1, end: 1000, recorded: 100, live: 90)],
        observedAt: 1000,
        stride: .8,
      ),
    );
    final restored = WorkoutDetails.fromJson(original.toJson());
    expect(restored.walkingSteps!.count, 100);
    expect(restored.walkingSteps!.distanceKm, .08);
    expect(WorkoutDetails.fromJson({}).walkingSteps, isNull);
  });
  test('cycling never starts a walking step session', () {
    final tracker = WorkoutStepTracker(
      platform: WalkingPlatform(),
      now: () => now,
    )..start(foot: false);
    expect(tracker.snapshot, isNull);
    expect(tracker.count, 0);
    tracker.dispose();
  });
}
