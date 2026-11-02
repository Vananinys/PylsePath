import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/community_activity.dart';
import 'package:pulsepath/models/community_post.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/shared_route.dart';
import 'package:pulsepath/services/community_activity_service.dart';
import 'package:pulsepath/widgets/community_activity_panel.dart';

SavedRoute ride(
  String id,
  DateTime? date, {
  double? meters = 10000,
  int? seconds = 3600,
  String? remote,
}) => SavedRoute(
  localId: id,
  remoteId: remote,
  title: 'Заезд',
  distance: meters == null ? 'неизвестно' : '10 км',
  duration: seconds == null ? 'неизвестно' : '1 ч',
  distanceMeters: meters,
  durationSeconds: seconds,
  createdAt: date,
  finishPoint: const LatLng(0, 0),
  routePoints: const [],
  activityType: ActivityType.cycling,
  surfaceSummary: '',
);
CommunityPost post(String id, {String author = 'friend', bool ride = true}) =>
    CommunityPost(
      id: id,
      authorId: author,
      authorName: 'Анна Белобородова',
      body: 'Прокатились',
      likeCount: 0,
      likedByMe: false,
      createdAt: DateTime(2026, 11, 2),
      routeAttachment: ride
          ? const SharedRoute(
              title: 'Поездка к озеру',
              kind: 'ride',
              distanceKm: 12,
              durationSeconds: 3600,
              points: [],
            )
          : null,
    );
void main() {
  test('calendar week counts known dates, excludes previous/future/unknown dates and remote duplicates', () {
    final rows = [
      ride('sun', DateTime(2026, 11, 1)),
      ride('mon', DateTime(2026, 11, 2), remote: 'cloud'),
      ride('duplicate', DateTime(2026, 11, 2), remote: 'cloud'),
      ride('wed', DateTime(2026, 11, 4)),
      ride('next', DateTime(2026, 11, 5)),
      ride('unknown', null),
    ];
    final result = CommunityWeekActivity.fromHistory(
      rows,
      now: DateTime(2026, 11, 4, 18),
    );
    expect(result.start, DateTime(2026, 11, 2));
    expect(result.count, 2);
    expect(result.distanceKm, 20);
    expect(result.activeSeconds, 7200);
  });
  test('missing measurements do not turn into fake zero totals', () {
    final result = CommunityWeekActivity.fromHistory([
      ride(
        'unknown-metrics',
        DateTime(2026, 11, 2),
        meters: null,
        seconds: null,
      ),
    ], now: DateTime(2026, 11, 4));
    expect(result.count, 1);
    expect(result.distanceKm, isNull);
    expect(result.activeSeconds, isNull);
  });
  test(
    'account change during loading rejects previous account results',
    () async {
      var owner = 'a';
      final pending = Completer<List<SavedRoute>>();
      final service = CommunityActivityService(
        currentOwner: () => owner,
        historyLoader: () => pending.future,
      );
      final future = service.loadMyWeek();
      final expected = expectLater(future, throwsStateError);
      owner = 'b';
      pending.complete([]);
      await expected;
    },
  );
  test(
    'friend ride selection keeps only permitted provided friend rides',
    () async {
      final service = CommunityActivityService(
        currentOwner: () => 'me',
        friendsLoader: () async => [
          post('text', ride: false),
          post('mine', author: 'me'),
          post('ride'),
        ],
      );
      expect((await service.loadFriendRides()).map((p) => p.id), ['ride']);
    },
  );
  testWidgets('week and friend states stay independent at 320px and 200%', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var fail = true, opened = false;
    final service = CommunityActivityService(
      currentOwner: () => 'me',
      historyLoader: () async => [],
      friendsLoader: () async {
        if (fail) throw StateError('offline');
        return [post('ride')];
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: CommunityActivityPanel(
              service: service,
              onOpenPost: (_) => opened = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Моя неделя'), findsOneWidget);
    expect(find.text('Не удалось загрузить поездки друзей'), findsOneWidget);
    expect(find.text('Пока нет опубликованных заездов друзей.'), findsNothing);
    await tester.ensureVisible(find.text('Поездки друзей'));
    await tester.tap(find.text('Поездки друзей'));
    await tester.pumpAndSettle();
    fail = false;
    await tester.ensureVisible(find.text('Повторить'));
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Поездка к озеру'));
    await tester.tap(find.text('Поездка к озеру'));
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
  });
}
