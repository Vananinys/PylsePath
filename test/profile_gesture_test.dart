// Проверки интерактивности плитки «Всего заездов» на экране профиля:
// тап открывает историю заездов, остальные плитки остаются некликабельными,
// а InkWell лежит внутри Card (иначе ripple был бы не виден).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/screens/profile_screen.dart';
import 'package:pulsepath/screens/workout_history_screen.dart';
import 'package:pulsepath/state/profile_provider.dart';
import 'package:pulsepath/data/workout_history_repository.dart';

void main() {
  setUp(WorkoutHistoryRepository.resetInstancesForTesting);
  testWidgets('тап по «Всего заездов» открывает историю заездов', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // Провайдер обязателен: без него экран падал бы с ошибкой (и он же —
    // общий кэш профиля; локальной копии быть не должно).
    final provider = ProfileProvider();
    await tester.pumpWidget(
      MaterialApp(home: ProfileScreen(provider: provider)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Всего заездов'), findsOneWidget);

    await tester.ensureVisible(find.text('Всего заездов'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Всего заездов'));
    await tester.pumpAndSettle();

    expect(find.byType(WorkoutHistoryScreen), findsOneWidget);
  });

  testWidgets('некликабельные плитки ничего не открывают', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // Провайдер обязателен: без него экран падал бы с ошибкой (и он же —
    // общий кэш профиля; локальной копии быть не должно).
    final provider = ProfileProvider();
    await tester.pumpWidget(
      MaterialApp(home: ProfileScreen(provider: provider)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Общий пробег'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Общий пробег'));
    await tester.pumpAndSettle();

    expect(find.byType(WorkoutHistoryScreen), findsNothing);
  });

  testWidgets('плитка «Всего заездов» содержит InkWell (ripple)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // Провайдер обязателен: без него экран падал бы с ошибкой (и он же —
    // общий кэш профиля; локальной копии быть не должно).
    final provider = ProfileProvider();
    await tester.pumpWidget(
      MaterialApp(home: ProfileScreen(provider: provider)),
    );
    await tester.pumpAndSettle();

    // InkWell должен быть ПРЕДКОМ текста (то есть внутри Card), иначе
    // ripple рисовался бы под карточкой и был бы не виден.
    final inkWell = find.ancestor(
      of: find.text('Всего заездов'),
      matching: find.byType(InkWell),
    );
    expect(inkWell, findsOneWidget);
  });
}
