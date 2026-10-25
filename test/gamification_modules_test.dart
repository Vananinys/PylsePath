import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/data/ui_modules.dart';
import 'package:pulsepath/models/friend_profile.dart';
import 'package:pulsepath/models/owner_award.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/walking_steps.dart';
import 'package:pulsepath/models/workout_details.dart';
import 'package:pulsepath/services/achievements_service.dart';
import 'package:pulsepath/services/achievement_journey.dart';
import 'package:pulsepath/widgets/module_settings_panel.dart';

SavedRoute session(
  DateTime? date, {
  int minutes = 20,
  ActivityType type = ActivityType.hiking,
  int steps = 0,
}) => SavedRoute(
  title: 'Test',
  distance: '',
  duration: '',
  distanceMeters: 1000,
  durationSeconds: minutes * 60,
  surfaceSummary: '',
  finishPoint: const LatLng(52, 85),
  routePoints: const [],
  activityType: type,
  createdAt: date,
  workoutDetails: WorkoutDetails(
    walkingSteps: steps == 0
        ? null
        : WalkingSteps(
            device: 'test',
            observedAt: 2000,
            windows: [
              StepWindow(start: 1000, end: 2000, recorded: steps, live: steps),
            ],
          ),
  ),
);

void main() {
  setUp(() {
    AchievementsService.bindToUser(null);
    AchievementsService.catalog = const [];
    AchievementsService.ownerIssued = const [];
  });
  test('map labels show names without stale update timestamps', () {
    final stale = FriendProfile(
      id: '1',
      username: 'Друг',
      liveLatitude: 52,
      liveLongitude: 85,
      liveUpdatedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      liveActivity: 'running',
    );
    expect(stale.mapLabel, 'Друг');
    final live = FriendProfile(
      id: '1',
      username: 'Друг',
      liveLatitude: 52,
      liveLongitude: 85,
      liveUpdatedAt: DateTime.now(),
      liveActivity: 'running',
      liveSpeedKmh: 8,
    );
    expect(live.mapLabel, contains('Бежит'));
    expect(live.mapLabel, isNot(contains('Обновлено')));
  });
  test(
    'existing granted medals keep identity and XP with clean public copy',
    () {
      AchievementsService.ownerIssued = [
        const OwnerAward(
          id: 'grant',
          kind: 'achievement',
          key: 'builtin:100 км за раз',
          label: '100 км за раз',
          icon: '🚩',
          equipped: false,
          grantedAt: null,
        ),
      ];
      final medal = AchievementJourney([]).medals
          .firstWhere((medal) => medal.id == 'builtin:100 км за раз');
      expect(medal.earned, isTrue);
      expect(medal.rarity, MedalRarity.legendary);
      expect(medal.badge.publicDescription, 'Один заезд от 100 км');
      expect(medal.category, 'Приключения');
    },
  );
  test('public award copy hides grant metadata and retains the condition', () {
    const badge = Achievement(
      icon: '🚩',
      title: '100 км',
      description: 'Выдано владельцем. Один заезд от 100 км',
      threshold: 100,
      earned: true,
    );
    expect(badge.publicDescription, 'Один заезд от 100 км');
    expect(badge.description, startsWith('Выдано владельцем.'));
    const special = Achievement(
      icon: '🏅',
      title: 'Особая',
      description: 'Награда владельца приложения',
      threshold: 1,
    );
    expect(special.publicDescription, 'Особая награда в вашей коллекции.');
  });
  test('step medals merge both sources once and exclude non-foot sessions', () {
    final date = DateTime(2026, 10, 24);
    final j = AchievementJourney([
      session(date, steps: 600),
      session(date, steps: 400),
      session(date, type: ActivityType.cycling, steps: 10000),
    ], now: date);
    final medal = j.medals.firstWhere(
      (m) => m.badge.title == '1000 шагов в тренировках',
    );
    expect(medal.earned, isTrue);
    expect(medal.current, 1000);
    expect(medal.category, 'Шаги');
    expect(
      j.medals
          .firstWhere((m) => m.badge.title == '5000 шагов в тренировках')
          .earned,
      isFalse,
    );
    expect(medal.story, contains('Отличная работа'));
    final restored = SavedRoute.fromJson(session(date, steps: 1000).toJson());
    expect(
      AchievementJourney([restored], now: date).medals
          .firstWhere((m) => m.badge.title == '1000 шагов в тренировках')
          .earned,
      isTrue,
    );
  });
  test('variety counts walking running cycling, not subtypes or cars', () {
    final date = DateTime(2026, 10, 24);
    List<SavedRoute> rides = [
      session(date),
      session(date, type: ActivityType.briskWalking),
      session(date, type: ActivityType.driving),
    ];
    JourneyMedal medal(String title) => AchievementJourney(
      rides,
      now: date,
    ).medals.firstWhere((m) => m.badge.title == title);
    expect(medal('Два ритма').earned, isFalse);
    rides.add(session(date, type: ActivityType.trailRunning));
    expect(medal('Два ритма').earned, isTrue);
    expect(medal('Три стихии').earned, isFalse);
    rides.add(session(date, type: ActivityType.cycling));
    expect(medal('Три стихии').earned, isTrue);
  });
  test('weekly goals exclude old undated future and driving records, reset on Monday', () {
    final now = DateTime(2026, 10, 24, 12);
    final rides = [
      session(DateTime(2026, 10, 19)),
      session(DateTime(2026, 10, 20)),
      session(DateTime(2026, 10, 24)),
      session(DateTime(2026, 10, 18)),
      session(DateTime(2026, 10, 25)),
      session(null),
      session(now, type: ActivityType.driving),
    ];
    final j = AchievementJourney(rides, now: now);
    expect(j.weeklyStart, DateTime(2026, 10, 19));
    expect(j.weeklyEnd, DateTime(2026, 10, 25));
    expect(j.weeklyGoals.map((g) => g.current), [3, 60, 3]);
    expect(j.weeklyGoals.every((g) => g.completed), isTrue);
    final next = AchievementJourney(rides, now: DateTime(2026, 10, 26));
    expect(next.weeklyGoals.every((g) => g.current == 0), isTrue);
    expect(next.xp, j.xp); // Weekly targets do not mint or remove XP.
  });
  test('every module has a unique group and a helpful description', () {
    final grouped = UiModules.groups.values.expand((ids) => ids).toList();
    expect(grouped.toSet(), UiModules.allIds);
    expect(grouped.length, grouped.toSet().length);
    for (final id in UiModules.allIds) {
      expect(UiModules.descriptions[id]!.length, greaterThan(40));
      expect(UiModules.titleOf(id), isNotNull);
    }
  });
  testWidgets(
    'module search and switching fit a narrow phone with large text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final selected = <String>{'history'};
      final pending = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: ModuleSettingsPanel(
                  enabled: selected,
                  preset: UiPreset.laconic,
                  onPreset: () {},
                  onChanged: (id, value) async {
                    if (value) selected.add(id);
                    await pending.future;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'XP');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SwitchListTile, 'Достижения'), findsOneWidget);
      expect(find.widgetWithText(SwitchListTile, 'Сообщество'), findsNothing);
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(selected, contains('achievements'));
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
