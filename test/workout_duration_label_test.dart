import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/workout_details.dart';

void main() {
  test('old saved durations are formatted without mutating stored values', () {
    SavedRoute route(String duration, {int? seconds}) => SavedRoute(
      title: 'Test',
      distance: '0 км',
      duration: duration,
      durationSeconds: seconds,
      surfaceSummary: '',
      finishPoint: const LatLng(52, 85),
      routePoints: const [],
      activityType: ActivityType.hiking,
    );
    final old = route('4325 сек');
    expect(old.displayDuration, '1 ч 12 мин');
    expect(old.duration, '4325 сек');
    expect(route('02:05').displayDuration, '2 мин 5 сек');
    expect(route('1 ч 12 мин').displayDuration, '1 ч 12 мин');
    expect(route('0 сек', seconds: 65).displayDuration, '1 мин 5 сек');
  });

  test('result duration changes units at minute and hour boundaries', () {
    const cases = {
      -1: '0 сек',
      0: '0 сек',
      59: '59 сек',
      60: '1 мин',
      61: '1 мин 1 сек',
      125: '2 мин 5 сек',
      3599: '59 мин 59 сек',
      3600: '1 ч',
      3601: '1 ч',
      4325: '1 ч 12 мин',
      90000: '25 ч',
    };
    for (final entry in cases.entries) {
      expect(workoutDurationLabel(Duration(seconds: entry.key)), entry.value);
    }
    expect(workoutTime(const Duration(seconds: 65)), '01:05');
  });
}
