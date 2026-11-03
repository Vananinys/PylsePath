import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/services/community_route_choices.dart';
import 'package:pulsepath/widgets/community_route_picker.dart';

SavedRoute route(String id, String title) => SavedRoute(
  localId: id,
  title: title,
  distance: '12 км',
  duration: '40 мин',
  surfaceSummary: '',
  finishPoint: const LatLng(0, 0),
  routePoints: const [],
  activityType: ActivityType.cycling,
  createdAt: DateTime(2026, 11, 1),
);
void main() {
  test(
    'both libraries retain their source even for identical local IDs',
    () async {
      final service = CommunityRouteChoices(
        currentUserId: () => 'owner',
        savedLoader: () async => [route('same', 'Маршрут')],
        workoutLoader: () async => [route('same', 'Тренировка')],
      );
      final items = await service.loadChoices();
      expect(items.map((c) => c.kind), ['route', 'ride']);
      expect(items.map((c) => c.key).toSet(), hasLength(2));
    },
  );
  test(
    'account switch during library load never returns previous owner data',
    () async {
      String? owner = 'a';
      final pending = Completer<List<SavedRoute>>();
      var workoutCalls = 0;
      final service = CommunityRouteChoices(
        currentUserId: () => owner,
        savedLoader: () => pending.future,
        workoutLoader: () async {
          workoutCalls++;
          return [];
        },
      );
      final result = service.loadChoices();
      owner = 'b';
      pending.complete([route('a', 'Private A')]);
      await expectLater(result, throwsStateError);
      expect(workoutCalls, 0);
    },
  );
  test('a guest cannot read the signed-in picker libraries', () async {
    var read = false;
    final service = CommunityRouteChoices(
      currentUserId: () => null,
      savedLoader: () async {
        read = true;
        return [];
      },
      workoutLoader: () async => [],
    );
    await expectLater(service.loadChoices(), throwsStateError);
    expect(read, isFalse);
  });
  testWidgets('picker searches saved routes and workouts separately', (
    tester,
  ) async {
    CommunityRouteChoice? chosen;
    final saved = route('saved', 'Берег реки');
    final workout = route('workout', 'Утренняя поездка');
    final service = CommunityRouteChoices(
      currentUserId: () => 'owner',
      savedLoader: () async => [saved],
      workoutLoader: () async => [workout],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CommunityRoutePicker(
          choicesService: service,
          onSelectedChoice: (value) => chosen = value,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Берег реки'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'НЕСУЩЕСТВУЕТ');
    await tester.pump();
    expect(
      find.text('Ничего не найдено. Попробуйте другое название.'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Тренировки'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Утренняя поездка'));
    await tester.pumpAndSettle();
    expect(find.text('Выбрано: Утренняя поездка'), findsOneWidget);
    await tester.tap(find.text('Прикрепить'));
    await tester.pump();
    expect(chosen!.kind, 'ride');
    expect(chosen!.route.localId, 'workout');
  });
  testWidgets('empty library and load error are distinct and retry works', (
    tester,
  ) async {
    var offline = true;
    final service = CommunityRouteChoices(
      currentUserId: () => 'owner',
      savedLoader: () async {
        if (offline) throw StateError('offline');
        return [];
      },
      workoutLoader: () async => [],
    );
    await tester.pumpWidget(
      MaterialApp(home: CommunityRoutePicker(choicesService: service)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Не удалось загрузить'), findsOneWidget);
    expect(find.text('Сохранённых маршрутов пока нет'), findsNothing);
    offline = false;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Сохранённых маршрутов пока нет'), findsOneWidget);
  });
  for (final brightness in Brightness.values) {
    testWidgets('route selection at 320px and 200 percent $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = CommunityRouteChoices(
        currentUserId: () => 'owner',
        savedLoader: () async => [
          route('saved', 'Длинное название маршрута рядом с рекой'),
        ],
        workoutLoader: () async => [],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: CommunityRoutePicker(choicesService: service),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Длинное название маршрута рядом с рекой'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Выбрано:'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('switching account after selection blocks confirmation', (
    tester,
  ) async {
    String? owner = 'a';
    CommunityRouteChoice? selected;
    final service = CommunityRouteChoices(
      currentUserId: () => owner,
      savedLoader: () async => [route('a-route', 'Маршрут A')],
      workoutLoader: () async => [],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CommunityRoutePicker(
          choicesService: service,
          onSelectedChoice: (choice) => selected = choice,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Маршрут A'));
    await tester.pump();
    owner = 'b';
    await tester.tap(find.text('Прикрепить'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(
      find.text('Аккаунт изменился. Откройте выбор маршрута заново.'),
      findsOneWidget,
    );
  });
}
