// Проверки блока «Прогресс» в профиле: переключение периодов, смена цели,
// пересчёт полосы прогресса и сохранение значений в SharedPreferences.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/screens/profile_screen.dart';
import 'package:pulsepath/models/progress_period.dart';
import 'package:pulsepath/state/profile_provider.dart';
import 'package:pulsepath/data/workout_history_repository.dart';

Map<String, dynamic> _ride(DateTime when, String distance) => {
  'title': 'Тренировка ${when.toString().substring(0, 16)}',
  'distance': distance,
  'duration': '30 мин',
  'surfaceSummary': 'Заезд',
  'finishLat': 52.52,
  'finishLon': 13.405,
  'routePoints': [
    [52.52, 13.405],
  ],
  'activityIndex': 0,
  'createdAt': when.millisecondsSinceEpoch,
};

/// Пары «сегодня 10 км» и «40 дней назад 5 км».
/// 40 дней назад гарантированно вне окна дня/недели/месяца (месяц начинается
/// не раньше 31 дня назад), но может попадать в год — поэтому для года
/// проверяем инвариант, а не точное число.
Future<void> _seedHistory() async {
  final now = DateTime.now();
  SharedPreferences.setMockInitialValues(<String, Object>{
    'workout_history_guest': jsonEncode(<Map<String, dynamic>>[
      _ride(now, '10.0 км'),
      _ride(now.subtract(const Duration(days: 40)), '5.0 км'),
    ]),
  });
}

Future<void> _pumpProfile(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(home: ProfileScreen(provider: ProfileProvider())),
  );
  await tester.pumpAndSettle();
}

/// Тап с прокруткой к цели: блок «Прогресс» находится ниже первого экрана,
/// и без `ensureVisible` тап уходит мимо (Flutter предупреждает warnIfMissed).
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

double _progressValue(WidgetTester tester) => tester
    .widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('profile-distance-goal-progress')),
    )
    .value!;

void main() {
  setUp(WorkoutHistoryRepository.resetInstancesForTesting);
  testWidgets(
    'legacy история без владельца не подставляется в гостевой профиль',
    (tester) async {
      final legacy = jsonEncode([_ride(DateTime.now(), '10.0 км')]);
      SharedPreferences.setMockInitialValues({'workout_history': legacy});
      await _pumpProfile(tester);
      expect(_progressValue(tester), 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('workout_history'), legacy);
    },
  );

  testWidgets(
    'повреждённая история не блокирует профиль, оригинал сохраняется рядом',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'workout_history_guest': '{broken',
      });
      await _pumpProfile(tester);
      // Битое хранилище больше не ломает экран: история стартует пустой,
      // новые заезды можно сохранять.
      expect(
        find.text('Не удалось загрузить профиль и историю. Данные не удалены.'),
        findsNothing,
      );
      expect(find.text('Всего заездов'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      // Оригинал нетронут в основном ключе и сохранён копией рядом —
      // данные можно восстановить вручную.
      expect(prefs.getString('workout_history_guest'), '{broken');
      expect(prefs.getString('workout_history_guest_damaged'), '{broken');
    },
  );

  testWidgets('по умолчанию месяц: считаются только заезды за этот месяц', (
    tester,
  ) async {
    await _seedHistory();
    await _pumpProfile(tester);

    expect(find.text('Прогресс за месяц'), findsOneWidget);
    expect(find.text('Пробег за месяц'), findsOneWidget);
    // Заезд 40-дневной давности в месячное окно не попадает.
    expect(find.text('10.0 км'), findsAtLeastNWidgets(1));
    // Цель по умолчанию для месяца — 400 км, 10 / 400 = 2.5%.
    expect(_progressValue(tester), closeTo(0.025, 0.0001));
  });

  testWidgets('переключатель меняет период, заголовок и расчёт', (
    tester,
  ) async {
    await _seedHistory();
    await _pumpProfile(tester);

    for (final label in <String>['День', 'Неделя', 'Месяц', 'Год']) {
      expect(find.text(label), findsOneWidget, reason: 'нет сегмента «$label»');
    }

    await _tap(tester, find.text('День'));
    expect(find.text('Прогресс за день'), findsOneWidget);
    expect(find.text('Пробег за день'), findsOneWidget);
    expect(find.text('10.0 км'), findsAtLeastNWidgets(1));

    await _tap(tester, find.text('Год'));
    expect(find.text('Прогресс за год'), findsOneWidget);
    // ВАЖНО: у каждого периода СВОЯ цель (у года — 4000 км), поэтому процент
    // сравнивать между периодами нельзя — считаем ожидание от цели года.
    // Заезд 40-дневной давности попадает в год, только если он в этом же
    // календарном году.
    final now = DateTime.now();
    final inThisYear = ProgressPeriod.year.contains(
      now.subtract(const Duration(days: 40)),
      now,
    );
    expect(
      _progressValue(tester),
      closeTo((inThisYear ? 15.0 : 10.0) / 4000.0, 0.0001),
    );

    // Выбор периода сохраняется в SharedPreferences.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('progress_period_guest'), 'year');
  });

  testWidgets('смена цели: диалог, пересчёт процента и сохранение', (
    tester,
  ) async {
    await _seedHistory();
    await _pumpProfile(tester);

    // Плашка цели кликабельна (внутри InkWell).
    final goalChip = find.ancestor(
      of: find.text('Цель: 400 км'),
      matching: find.byType(InkWell),
    );
    expect(goalChip, findsOneWidget);

    await _tap(tester, find.text('Цель: 400 км'));

    expect(find.text('Цель на месяц'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '250');
    await _tap(tester, find.text('Сохранить'));

    // Новое значение в UI и пересчитанный процент: 10 / 250 = 4%.
    expect(find.text('Цель: 250 км'), findsOneWidget);
    expect(find.text('4 %'), findsOneWidget);
    expect(_progressValue(tester), closeTo(0.04, 0.0001));

    // И оно сохранено локально именно для месячного периода.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('progress_goal_month_guest'), 250.0);
  });

  testWidgets('цель вне диапазона 10..5000 не сохраняется', (tester) async {
    await _seedHistory();
    await _pumpProfile(tester);

    await _tap(tester, find.text('Цель: 400 км'));

    await tester.enterText(find.byType(TextFormField), '5');
    await _tap(tester, find.text('Сохранить'));

    // Диалог остался открыт, показана ошибка, цель не изменилась.
    expect(find.text('Цель на месяц'), findsOneWidget);
    expect(
      find.textContaining('Цель должна быть от 10 до 5000 км'),
      findsWidgets,
    );
    expect(find.text('4 %'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('progress_goal_month_guest'), isNull);
  });

  testWidgets('цели периодов хранятся независимо', (tester) async {
    await _seedHistory();
    await _pumpProfile(tester);

    // Меняем цель для дня.
    await _tap(tester, find.text('День'));
    await _tap(tester, find.text('Цель: 20 км'));
    await tester.enterText(find.byType(TextFormField), '30');
    await _tap(tester, find.text('Сохранить'));
    expect(find.text('Цель: 30 км'), findsOneWidget);

    // Возвращаемся к месяцу — там по-прежнему своя цель.
    await _tap(tester, find.text('Месяц'));
    expect(find.text('Цель: 400 км'), findsOneWidget);
  });
}
