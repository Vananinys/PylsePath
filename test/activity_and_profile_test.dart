import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/services/activity_service.dart';
import 'package:pulsepath/services/profile_presentation_service.dart';
import 'package:pulsepath/widgets/activity_panel.dart';
import 'package:pulsepath/widgets/map_ui_overlays.dart';
import 'package:pulsepath/widgets/profile_identity_card.dart';
import 'package:pulsepath/widgets/widget_size_observer.dart';

final now = DateTime(2026, 10, 21, 12);
SavedRoute workout(
  int ago, {
  double km = .1,
  int seconds = 600,
  ActivityType type = ActivityType.hiking,
}) => SavedRoute(
  title: 'Активность',
  distance: '',
  duration: '',
  surfaceSummary: '',
  distanceMeters: km * 1000,
  durationSeconds: seconds,
  activityType: type,
  createdAt: now.subtract(Duration(days: ago)),
  finishPoint: const LatLng(55, 83),
  routePoints: const [],
);

void main() {
  test('flame extends once per calendar day and small workouts combine', () {
    final s = ActivitySummary.fromRides([
      workout(1),
      workout(2),
      workout(0, seconds: 300),
      workout(0, seconds: 300),
    ], now: now);
    expect(s.streak, 3);
    expect(s.activeDays, 3);
    expect(s.activeToday, isTrue);
    expect(s.today.rides, 2);
    expect(s.today.seconds, 600);
    expect(s.week.last, isTrue);
  });
  test('today grace, missed day reset and best series remain distinct', () {
    final rides = [workout(1), workout(2), workout(4), workout(5), workout(6)];
    final s = ActivitySummary.fromRides(rides, now: now);
    expect(s.streak, 2);
    expect(s.best, 3);
    expect(s.activeToday, isFalse);
    expect(
      ActivitySummary.fromRides(
        rides,
        now: now.add(const Duration(days: 1)),
      ).streak,
      0,
    );
  });
  test(
    'driving, future data and tiny unsustained activity cannot extend flame',
    () {
      final s = ActivitySummary.fromRides([
        workout(0, type: ActivityType.driving, km: 100, seconds: 3600),
        workout(-1),
        workout(0, km: .1, seconds: 100),
      ], now: now);
      expect(s.streak, 0);
      expect(s.activeDays, 0);
      expect(s.total.rides, 2);
      expect(s.dayProgress, closeTo(1 / 6, .0001));
    },
  );
  test('distance alternative and midnight use local calendar days', () {
    expect(
      ActivitySummary.fromRides([
        workout(0, km: 1, seconds: 100),
      ], now: now).activeToday,
      isTrue,
    );
    final w = workout(0, km: 1, seconds: 100);
    final nextMorning = DateTime(2026, 10, 22, 0, 1);
    final s = ActivitySummary.fromRides([w], now: nextMorning);
    expect(s.streak, 1);
    expect(s.activeToday, isFalse);
  });
  test('recorded calendar day survives JSON, cloud and library copies', () {
    final route = SavedRoute(
      title: 'Заезд',
      distance: '',
      duration: '',
      surfaceSummary: '',
      distanceMeters: 1000,
      durationSeconds: 600,
      activityType: ActivityType.cycling,
      createdAt: now,
      activityLocalDay: '2026-10-20',
      finishPoint: const LatLng(55, 83),
      routePoints: const [],
    );
    final restored = SavedRoute.fromJson(route.toJson())
        .withSyncState(cloudSynced: true)
        .withLibraryDetails(title: 'Новое имя');
    expect(restored.activityLocalDay, '2026-10-20');
    final s = ActivitySummary.fromRides([restored], now: now);
    expect(s.activeToday, isFalse);
    expect(s.streak, 1);
  });
  test('undated legacy history cannot keep renewing the flame', () {
    final old = SavedRoute(
      title: 'Старый заезд',
      distance: '2 км',
      duration: '30 мин',
      surfaceSummary: '',
      activityType: ActivityType.cycling,
      finishPoint: const LatLng(55, 83),
      routePoints: const [],
    );
    final s = ActivitySummary.fromRides([old], now: now);
    expect(s.total.rides, 1);
    expect(s.activeToday, isFalse);
    expect(s.streak, 0);
  });
  testWidgets('large public avatar never overlaps username', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const avatarKey = Key('public-avatar');
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: ProfileIdentityCard(
                name: 'DUSHNILA',
                avatar: CircleAvatar(key: avatarKey, radius: 48),
                style: ProfilePresentation(frame: 'double'),
                status: 'Мега СИГМА',
                city: 'Бийск',
                sport: 'Город',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.text('DUSHNILA')).top,
      greaterThan(tester.getRect(find.byKey(avatarKey)).bottom),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('daily and all-time stats fit a small phone with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 800),
            textScaler: TextScaler.linear(1.5),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ActivityPanel(
                  summary: ActivitySummary.fromRides([
                    workout(0),
                    workout(1),
                  ], now: now),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Активность за всё время'), findsOneWidget);
  });
  testWidgets('private activity does not render aggregate values', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActivityPanel(
            summary: ActivitySummary(
              day: now,
              visible: false,
              total: const ActivityTotals(km: 1234),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('скрыл'), findsOneWidget);
    expect(find.textContaining('1234'), findsNothing);
  });
  testWidgets(
    'map controls respect measured HUD boundary and remain scrollable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = MapController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                MapOverlays(
                  mapController: controller,
                  autoRotateMap: false,
                  isFollowingUser: false,
                  isWorkoutActive: true,
                  isWorkoutPaused: false,
                  currentHeading: 0,
                  currentLocation: const LatLng(55, 83),
                  onAutoRotateChanged: (_) {},
                  onFollowUser: () {},
                  bottomOffset: 390,
                  cameraLockModeLabel: 'Камера',
                  cameraLockModeIcon: Icons.near_me,
                  onCameraLockModePressed: () {},
                  mapRotation: 0,
                  onCompassPressed: () {},
                  onLockScreen: () {},
                  onScreenUnlocked: () {},
                  mapLayerLabel: 'Карта',
                  onMapLayerPressed: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final panel = tester.getRect(find.byType(SingleChildScrollView));
      expect(panel.bottom, lessThanOrEqualTo(310));
      expect(panel.top, greaterThanOrEqualTo(140));
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('HUD size observer reports changing content height', (
    tester,
  ) async {
    final sizes = <Size>[];
    Future<void> render(double height) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: WidgetSizeObserver(
              onSize: sizes.add,
              child: SizedBox(width: 300, height: height),
            ),
          ),
        ),
      ),
    );
    await render(120);
    await tester.pump();
    await render(360);
    await tester.pump();
    expect(sizes.map((s) => s.height), containsAllInOrder([120, 360]));
  });
  testWidgets('render activity profile preview', (tester) async {
    if (!const bool.fromEnvironment('RENDER_ACTIVITY_PREVIEW')) return;
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      for (final font in {
        'PreviewSans': 'C:/Windows/Fonts/segoeui.ttf',
        'MaterialIcons': 'C:/src/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      }.entries) {
        final loader = FontLoader(font.key);
        final bytes = await File(font.value).readAsBytes();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      }
    });
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            fontFamily: 'PreviewSans',
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
          ),
          home: Scaffold(
            appBar: AppBar(title: const Text('Профиль райдера')),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const ProfileIdentityCard(
                  name: 'DUSHNILA',
                  avatar: CircleAvatar(
                    radius: 48,
                    child: Icon(Icons.person, size: 48),
                  ),
                  style: ProfilePresentation(accent: 'violet', frame: 'double'),
                  status: 'Мега СИГМА',
                  city: 'Бийск',
                  sport: 'Город',
                ),
                const SizedBox(height: 20),
                ActivityPanel(
                  summary: ActivitySummary.fromRides([
                    workout(0, km: 12),
                    workout(1),
                    workout(2),
                  ], now: now),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/previews/activity_profile.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
