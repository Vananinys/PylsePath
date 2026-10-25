import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/ui_snapshot_cache.dart';
import 'package:pulsepath/models/community_post.dart';
import 'package:pulsepath/widgets/community_feed.dart';
import 'package:pulsepath/data/user_profile_repository.dart';
import 'package:pulsepath/models/user_profile.dart';
import 'package:pulsepath/screens/garage_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'Successful empty garage mirror clears selected vehicle locally',
    () async {
      final repository = UserProfileRepository();
      await repository.load();
      final bike = Bike(
        name: 'Мой велосипед',
        weightKg: 14,
        type: BikeType.city,
      );
      await repository.updateGarageCache(garage: [bike], selectedBike: bike);
      await repository.updateGarageCache(garage: []);
      final restored = UserProfileRepository();
      await restored.load();
      expect(restored.profile.garage, isEmpty);
      expect(restored.profile.selectedBike, isNull);
    },
  );

  testWidgets('Saved garage displays without an available server', (
    tester,
  ) async {
    final repository = UserProfileRepository();
    await repository.load();
    final bike = Bike(
      name: 'Локальный велосипед',
      weightKg: 14,
      type: BikeType.city,
    );
    await repository.updateGarageCache(garage: [bike], selectedBike: bike);
    await tester.pumpWidget(const MaterialApp(home: GarageScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Локальный велосипед'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'Snapshots are isolated by account and survive a new cache instance',
    () async {
      await const UiSnapshotCache('friends', 'one').write([
        {'id': 'friend'},
      ]);
      expect(await const UiSnapshotCache('friends', 'two').read(), isNull);
      expect(await const UiSnapshotCache('friends', null).read(), isNull);
      expect(
        (await const UiSnapshotCache('friends', 'one').read())!.single['id'],
        'friend',
      );
    },
  );

  test('Expired, future-dated and corrupt snapshots are ignored', () async {
    const cache = UiSnapshotCache('test', 'one');
    final now = DateTime.utc(2026, 10, 17);
    await cache.write([
      {'id': 'one'},
    ], now: now);
    expect(await cache.read(now: now.add(const Duration(hours: 25))), isNull);
    expect(
      await cache.read(now: now.subtract(const Duration(seconds: 1))),
      isNull,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cache.key, 'broken json');
    expect(await cache.read(), isNull);
  });

  test(
    'Successful empty snapshots remove stale entries and size is bounded',
    () async {
      const cache = UiSnapshotCache('friends', 'one');
      await cache.write(List.generate(150, (i) => {'id': '$i'}));
      expect((await cache.read())!.length, 100);
      await cache.write([]);
      expect(await cache.read(), isEmpty);
    },
  );

  test('Community snapshot preserves display data without a route track', () {
    final post = CommunityPost(
      id: 'post',
      authorId: 'author',
      authorName: 'Райдер',
      body: 'Поездка',
      likeCount: 3,
      likedByMe: true,
      createdAt: DateTime.utc(2026),
      commentsCount: 2,
      rideDistanceKm: 15,
      photoUrls: const ['https://example.com/photo.jpg'],
    );
    final restored = CommunityPost.fromSnapshot(post.toSnapshot());
    expect(restored.toSnapshot(), post.toSnapshot());
    expect(restored.toSnapshot().containsKey('routePoints'), isFalse);
  });

  testWidgets('Saved feed remains visible when the network is unavailable', (
    tester,
  ) async {
    final post = CommunityPost(
      id: 'post',
      authorId: 'author',
      authorName: 'Райдер',
      body: 'Сохранённая поездка',
      likeCount: 0,
      likedByMe: false,
      createdAt: DateTime.now(),
    );
    await const UiSnapshotCache(
      'community_feed',
      null,
    ).write([post.toSnapshot()]);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: CommunityFeed())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Сохранённая поездка'), findsOneWidget);
    expect(
      find.text('Сохранённая лента · не удалось обновить'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
