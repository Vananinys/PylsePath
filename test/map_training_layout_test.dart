import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/data/saved_routes_repository.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/workout_details.dart';
import 'package:pulsepath/ui/app_theme.dart';
import 'package:pulsepath/widgets/map_credits.dart';
import 'package:pulsepath/widgets/pre_ride_widget.dart';
import 'package:pulsepath/widgets/ride_preparation_panel.dart';
import 'package:pulsepath/widgets/workout_stats_bottom_sheet.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SavedRoutesRepository.resetInstancesForTesting();
    WorkoutHistoryRepository.resetInstancesForTesting();
  });
  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets(
      'training goals stay readable and selectable at text scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = MapNavigationController();
        await tester.pumpWidget(
          MaterialApp(
            theme: pulsePathTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  height: 700,
                  child: PreRideWidget(
                    selectedVehicle: null,
                    onSelectVehicle: () {},
                    autoPauseEnabled: false,
                    onAutoPauseChanged: (_) {},
                    sportMode: SportMode.walking,
                    onSportModeChanged: (_) {},
                    onStartRide: () {},
                    onCollapse: () {},
                    preparation: RidePreparationPanel(
                      controller: controller,
                      showGps: false,
                      onSharingChanged: (_) {},
                      onGpsRetry: () async {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Настройки тренировки'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Цель и интервалы'));
        await tester.tap(find.text('Цель и интервалы'));
        await tester.pumpAndSettle();
        final goal = find.widgetWithText(ChoiceChip, '200 ккал');
        await tester.ensureVisible(goal);
        await tester.pumpAndSettle();
        expect(tester.getSize(goal).height, greaterThanOrEqualTo(48));
        await tester.tap(goal);
        await tester.pumpAndSettle();
        expect(controller.workoutGoal!.kind, WorkoutGoalKind.calories);
        expect(controller.workoutGoal!.target, 200);
        expect(find.byType(ErrorWidget), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }
  testWidgets('expanded workout uses only its own drag handle', (tester) async {
    final controller = MapNavigationController()..startWorkout();
    await tester.pumpWidget(
      MaterialApp(
        theme: pulsePathTheme(),
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
    await tester.tap(find.text('Подробнее'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<BottomSheet>(find.byType(BottomSheet)).showDragHandle,
      false,
    );
    expect(find.bySemanticsLabel('Свернуть тренировку'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets(
    'map attribution remains visible without stretching across the map',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: const [
                Positioned(top: 12, right: 12, child: MapCredits()),
              ],
            ),
          ),
        ),
      );
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      expect(
        tester.getSize(find.byType(MapCredits)).width,
        lessThanOrEqualTo(228),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
