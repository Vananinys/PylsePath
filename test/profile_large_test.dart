import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/screens/profile_screen.dart';
import 'package:pulsepath/state/profile_provider.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/ui/app_theme.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'Actual progress and personal details at 320px and 200% $brightness',
      (tester) async {
        WorkoutHistoryRepository.resetInstancesForTesting();
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: pulsePathTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: ProfileScreen(provider: ProfileProvider()),
          ),
        );
        await tester.pumpAndSettle();
        for (
          var attempt = 0;
          attempt < 5 && find.text('Прогресс').evaluate().isEmpty;
          attempt++
        ) {
          await tester.drag(
            find.byType(NestedScrollView),
            const Offset(0, -400),
          );
          await tester.pumpAndSettle();
        }
        await Scrollable.ensureVisible(
          tester.element(find.text('Прогресс')),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Прогресс'));
        await tester.pumpAndSettle();
        await tester.drag(
          find.byType(NestedScrollView),
          const Offset(0, -1000),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Обо мне'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Обо мне'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
