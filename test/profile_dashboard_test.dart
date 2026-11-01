import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/screens/profile_screen.dart';
import 'package:pulsepath/state/profile_provider.dart';
import 'package:pulsepath/services/profile_presentation_service.dart';
import 'package:pulsepath/widgets/profile_dashboard.dart';
import 'package:pulsepath/widgets/profile_identity_card.dart';
import 'package:pulsepath/ui/app_theme.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'Profile sections and real actions fit 320px 200% $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var edits = 0, styles = 0, history = 0, training = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.teal,
                brightness: brightness,
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: ProfileDashboard(
              identity: const Text('Тестовый профиль'),
              stats: const ProfileSummaryGrid(
                distance: '128.4 км',
                workouts: '14',
                duration: '12 ч 35 мин',
                elevation: '345 м',
              ),
              awards: const Text('Награды профиля'),
              progress: const Text('Цель на месяц'),
              activity: const Text('Моя активность'),
              garage: const Text('Техника и снаряжение'),
              details: const Text('Рост и вес'),
              privacy: const Text('Видимость активности настроена'),
              onHistory: () => history++,
              onTraining: () => training++,
              onEdit: () => edits++,
              onCustomize: () => styles++,
              onRefresh: () async {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Личные данные'));
        await tester.tap(find.text('Оформление'));
        expect(edits, 1);
        expect(styles, 1);
        await tester.drag(
          find.byType(NestedScrollView),
          const Offset(0, -1000),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('История тренировок'),
          300,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.text('История тренировок'));
        expect(history, 1);
        await tester.scrollUntilVisible(
          find.text('Тренировочный центр'),
          300,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.text('Тренировочный центр'));
        expect(training, 1);
        await tester.tap(find.text('Прогресс'));
        await tester.pumpAndSettle();
        expect(find.text('Цель на месяц'), findsOneWidget);
        await tester.ensureVisible(find.text('Гараж'));
        await tester.tap(find.text('Гараж'));
        await tester.pumpAndSettle();
        expect(find.text('Техника и снаряжение'), findsOneWidget);
        await tester.ensureVisible(find.text('Обо мне'));
        await tester.tap(find.text('Обо мне'));
        await tester.pumpAndSettle();
        expect(find.text('Рост и вес'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('UI beta profile keeps working local details and goal editing', (
    tester,
  ) async {
    WorkoutHistoryRepository.resetInstancesForTesting();
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(home: ProfileScreen(provider: ProfileProvider())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Мой профиль'), findsOneWidget);
    await tester.ensureVisible(find.text('Личные данные'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Личные данные'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsWidgets);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Прогресс'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Прогресс'));
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.text('Цель: 400 км')),
      alignment: .5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Цель: 400 км'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '250');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Цель: 250 км'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getDouble(
        'progress_goal_month_guest',
      ),
      250,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  if (const bool.fromEnvironment('CAPTURE_PROFILE')) {
    for (final brightness in Brightness.values) {
      testWidgets('Profile preview $brightness', (tester) async {
        await tester.runAsync(() async {
          for (final fontEntry in {
            'Segoe UI': 'C:/Windows/Fonts/segoeui.ttf',
            'MaterialIcons': 'C:/src/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
          }.entries) {
            final font = FontLoader(fontEntry.key)
              ..addFont(
                File(fontEntry.value).readAsBytes().then(ByteData.sublistView),
              );
            await font.load();
          }
        });
        tester.view.physicalSize = const Size(390, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: pulsePathTheme(brightness: brightness).copyWith(
              textTheme: pulsePathTheme(brightness: brightness).textTheme
                  .apply(fontFamily: 'Segoe UI'),
            ),
            home: RepaintBoundary(
              key: key,
              child: ProfileDashboard(
                identity: const ProfileIdentityCard(
                  name: 'Тестовый профиль',
                  status: 'Велосипед, прогулки и новые маршруты',
                  city: 'Томск',
                  sport: 'Город',
                  avatar: CircleAvatar(
                    radius: 40,
                    child: Icon(Icons.person, size: 40),
                  ),
                  style: ProfilePresentation(),
                ),
                stats: const ProfileSummaryGrid(
                  distance: '128.4 км',
                  workouts: '14',
                  duration: '12 ч 35 мин',
                  elevation: '345 м',
                ),
                awards: const Text('Награды профиля'),
                progress: const Text('Цель на месяц'),
                activity: const Text('Моя активность'),
                garage: const Text('Мой гараж'),
                details: const Text('Личные данные'),
                privacy: const Text('Видимость активности'),
                onHistory: () {},
                onTraining: () {},
                onEdit: () {},
                onCustomize: () {},
                onRefresh: () async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('audit/2026-11-01/profile/profile-${brightness.name}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
