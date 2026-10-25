import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/friend_profile.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/screens/achievements_screen.dart';
import 'package:pulsepath/services/achievements_service.dart';
import 'package:pulsepath/widgets/map_sticker_flight.dart';

void main() {
  test('Empty history offers 52 locked achievements', () {
    final badges = AchievementsService.badges([]);
    expect(badges.length, 52);
    expect(badges.every((badge) => !badge.earned), isTrue);
    expect(badges.map((badge) => badge.title).toSet().length, 52);
  });

  test('Completed ride unlocks the correct distance and time thresholds', () {
    final ride = SavedRoute(
      title: 'Тест',
      distance: '10 км',
      duration: '1 ч',
      surfaceSummary: '',
      finishPoint: const LatLng(55, 83),
      routePoints: [],
      activityType: ActivityType.cycling,
      elevationGainMeters: 100,
    );
    final badges = AchievementsService.badges([ride]);
    bool earned(String title) =>
        badges.firstWhere((b) => b.title == title).earned;
    expect(earned('Первый заезд'), isTrue);
    expect(earned('10 км пути'), isTrue);
    expect(earned('10 км за раз'), isTrue);
    expect(earned('1 ч движения'), isTrue);
    expect(earned('25 км за раз'), isFalse);
  });

  test('Live activity, pause and stale positions have distinct statuses', () {
    FriendProfile friend({
      bool paused = false,
      DateTime? date,
      String activity = 'running',
    }) => FriendProfile(
      id: '1',
      username: 'Друг',
      liveSpeedKmh: 8.5,
      liveActivity: activity,
      livePaused: paused,
      liveUpdatedAt: date ?? DateTime.now(),
    );
    expect(friend().motionText, 'Бежит · 8.5 км/ч');
    expect(friend(activity: 'hiking').motionText, 'Идёт пешком · 8.5 км/ч');
    expect(friend(paused: true).motionText, 'На паузе');
    expect(
      friend(date: DateTime.now().subtract(const Duration(minutes: 1)))
          .motionText,
      startsWith('Обновлено'),
    );
    expect(
      const FriendProfile(id: 'old', username: 'Друг').motionText,
      isNot(contains('км/ч')),
    );
  });

  testWidgets(
    'Empty achievement screen displays the catalog on a narrow phone',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      WorkoutHistoryRepository.resetInstancesForTesting();
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const MaterialApp(home: AchievementsScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Ваши цели недели'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('Ваши достижения впереди'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Ваши достижения впереди'), findsOneWidget);
      for (
        var attempt = 0;
        attempt < 15 && find.text('Первый заезд').evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -200));
        await tester.pumpAndSettle();
      }
      expect(find.text('Первый заезд'), findsAtLeastNWidgets(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Sticker burst remains valid throughout the animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 64,
              height: 64,
              child: StickerFlight(
                emoji: '🔥',
                from: Offset(20, 100),
                to: Offset(20, 20),
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
