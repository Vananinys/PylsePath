import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/models/shared_route.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/chat_message.dart';
import 'package:pulsepath/models/community_post.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/workout_details.dart';
import 'package:pulsepath/data/chat_local_store.dart';
import 'package:pulsepath/widgets/chat_reply_preview.dart';
import 'package:pulsepath/widgets/shared_route_card.dart';
import 'package:pulsepath/widgets/route_details_bottom_sheet.dart';

SavedRoute sample() => SavedRoute(
  title: 'Вечерний круг',
  distance: '12.5 км',
  duration: '48 мин',
  surfaceSummary: '',
  finishPoint: const LatLng(55, 83),
  routePoints: const [
    LatLng(55, 83),
    LatLng(55.01, 83.01),
    LatLng(55.015, 83.03),
    LatLng(55.008, 83.04),
    LatLng(55, 83),
  ],
  activityType: ActivityType.cycling,
  workoutDetails: const WorkoutDetails(segmentStarts: [0, 3]),
);

class _PreviewTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      const AssetImage('assets/maptiler-logo.png');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final windows = Platform.environment['WINDIR'];
    if (windows != null) {
      final file = File('$windows/Fonts/arial.ttf');
      if (await file.exists()) {
        await (FontLoader('Roboto')..addFont(
              Future.value(ByteData.sublistView(await file.readAsBytes())),
            ))
            .load();
      }
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('Shared rides are independent of cloud sync and preserve segment boundaries', () {
    final route = sample();
    expect(route.remoteId, isNull);
    final shared = SharedRoute.fromSavedRoute(route);
    final restored = SharedRoute.tryParse(
      jsonDecode(jsonEncode(shared.toJson())),
    )!;
    expect(restored.distanceKm, 12.5);
    expect(restored.points, hasLength(5));
    expect(restored.segments.map((s) => s.length), [3, 2]);
    expect(restored.toSavedRoute().workoutDetails.segmentStarts, [0, 3]);
    expect(
      SharedRoute.fromSavedRoute(route, includeTrack: false).points,
      isEmpty,
    );
    expect(shared.toJson().containsKey('notes'), isFalse);
  });
  test('Oversized or invalid route payloads do not break message decoding', () {
    final raw = SharedRoute.fromSavedRoute(sample()).toJson();
    raw['points'] = [
      [95, 83],
    ];
    expect(SharedRoute.tryParse(raw), isNull);
    raw['points'] = List.generate(1202, (_) => [55, 83]);
    expect(SharedRoute.tryParse(raw), isNull);
  });
  test('A failed route message survives local reopening and retry without losing its card', () async {
    final route = SharedRoute.fromSavedRoute(sample());
    final message = ChatMessage(
      id: 'message',
      senderId: 'me',
      receiverId: 'friend',
      createdAt: DateTime.now(),
      routeAttachment: route,
      delivery: MessageDelivery.sending,
    );
    final store = ChatLocalStore('me', 'friend', currentOwner: () => 'me');
    await store.saveMessages([message]);
    final restored = (await store.readMessages()).single;
    expect(restored.delivery, MessageDelivery.failed);
    expect(restored.routeAttachment!.title, 'Вечерний круг');
    expect(
      restored.withDelivery(MessageDelivery.sent).routeAttachment!.points,
      hasLength(5),
    );
    final post = CommunityPost.fromRow(
      {
        'id': 'p',
        'author_id': 'me',
        'body': 'Тест',
        'created_at': DateTime.now().toIso8601String(),
        'route_attachment': route.toJson(),
      },
      authorById: {},
      likeCountByPost: {},
      likedByMePosts: {},
      rideById: {},
    );
    expect(post.rideId, isNull);
    expect(post.routeAttachment!.distanceKm, 12.5);
    expect(
      CommunityPost.fromSnapshot(post.toSnapshot()).routeAttachment!.title,
      'Вечерний круг',
    );
  });
  testWidgets('Route card and reply preview fit a narrow phone', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    final route = SharedRoute.fromSavedRoute(sample());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SharedRouteCard(route: route, tileProvider: _PreviewTiles()),
                  const SizedBox(height: 20),
                  ChatReplyPreview(
                    message: ChatMessage(
                      id: 'm',
                      senderId: 'me',
                      receiverId: 'friend',
                      createdAt: DateTime.now(),
                      routeAttachment: route,
                    ),
                    author: 'Сергей',
                  ),
                  const SizedBox(height: 12),
                  const Text('Поехали вечером 👍'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/shared_route_preview.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
  testWidgets(
    'The route panel expands, collapses and keeps navigation reachable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      double extent = .45;
      var started = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<DraggableScrollableNotification>(
              onNotification: (event) {
                extent = event.extent;
                return false;
              },
              child: Stack(
                children: [
                  Positioned.fill(
                    child: RouteDetailsBottomSheet(
                      finishAddress: 'Тестовый маршрут',
                      finishPoint: const LatLng(55, 83),
                      selectedActivity: ActivityType.cycling,
                      activityTypes: ActivityType.values,
                      routeDistanceKm: 12.5,
                      routeDurationMin: 48,
                      elevationGainMeters: 0,
                      elevationLossMeters: 0,
                      surfaceInfo: null,
                      isLoadingRoute: false,
                      isBookmarked: false,
                      isNavigating: false,
                      onClearRoute: () {},
                      onActivityChanged: (_) {},
                      onToggleBookmark: () {},
                      onToggleNavigation: () => started = true,
                      onShareRoute: () {},
                      formatDuration: (_) => '48 мин',
                      formatETA: (_) => 'до 18:00',
                      calculateCalories: () => 420,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.drag(find.text('Тестовый маршрут'), const Offset(0, -260));
      await tester.pumpAndSettle();
      expect(extent, greaterThan(.7));
      await tester.ensureVisible(find.text('В путь'));
      await tester.tap(find.text('В путь'));
      await tester.pump();
      expect(started, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
