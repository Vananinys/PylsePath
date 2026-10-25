import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/data/saved_routes_repository.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/services/workout_step_tracker.dart';
import 'package:pulsepath/widgets/workout_stats_bottom_sheet.dart';
import 'package:pulsepath/screens/ride_dashboard_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SavedRoutesRepository.resetInstancesForTesting();
    WorkoutHistoryRepository.resetInstancesForTesting();
  });
  testWidgets(
    'walking mini panel shows speed and session steps, pace lives on dashboard',
    (tester) async {
      final now = DateTime.now();
      final tracker = WorkoutStepTracker(now: () => now);
      final controller = MapNavigationController(stepTracker: tracker)
        ..setSportMode(SportMode.walking)
        ..startWorkout();
      tracker.acceptSensor({'count': 100, 'at': now.millisecondsSinceEpoch});
      tracker.acceptSensor({'count': 115, 'at': now.millisecondsSinceEpoch});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkoutStatsBottomSheet(
              controller: controller,
              savedRoutesRepo: SavedRoutesRepository(),
              onPauseResumePressed: () {},
              onFinishPressed: () {},
            ),
          ),
        ),
      );
      expect(find.text('км/ч'), findsOneWidget);
      expect(find.text('средний темп'), findsNothing);
      expect(find.text('15 шагов'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: RideDashboardScreen(controller: controller, onFinish: () {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Средний темп'), findsOneWidget);
      expect(find.text('15 шагов'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'cycling mini panel retains remaining statistics without a walking counter',
    (tester) async {
      final controller = MapNavigationController()..startWorkout();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkoutStatsBottomSheet(
              controller: controller,
              savedRoutesRepo: SavedRoutesRepository(),
              onPauseResumePressed: () {},
              onFinishPressed: () {},
            ),
          ),
        ),
      );
      expect(find.text('средняя'), findsNothing);
      await tester.tap(find.text('Подробнее'));
      await tester.pumpAndSettle();
      expect(find.text('средняя'), findsOneWidget);
      expect(find.text('максимальная'), findsOneWidget);
      expect(find.text('набор высоты'), findsOneWidget);
      expect(find.textContaining('шагов'), findsNothing);
      expect(find.text('средний темп'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
