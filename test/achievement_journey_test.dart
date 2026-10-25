import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/services/achievements_service.dart';
import 'package:pulsepath/services/achievement_journey.dart';
import 'package:pulsepath/widgets/achievement_hub.dart';
import 'package:pulsepath/widgets/ride_achievement_banner.dart';

SavedRoute ride(double km, {int minutes = 30}) => SavedRoute(
  title: 'Тренировка',
  distance: '',
  duration: '',
  surfaceSummary: '',
  distanceMeters: km * 1000,
  activityType: ActivityType.cycling,
  durationSeconds: minutes * 60,
  finishPoint: const LatLng(55, 83),
  routePoints: const [],
  createdAt: DateTime(2026, 10, 21),
);

void main() {
  setUp(() {
    AchievementsService.catalog = const [];
    AchievementsService.ownerIssued = const [];
  });
  test('progress uses actual units and keeps original award identities', () {
    final j = AchievementJourney([ride(2.5, minutes: 30)]);
    final distance = j.medals.firstWhere((m) => m.id == 'builtin:5 км пути');
    expect(distance.progress, .5);
    expect(distance.remainingText, 'Осталось 2.5 км');
    final time = j.medals.firstWhere((m) => m.badge.title == '1 ч движения');
    expect(time.progress, .5);
    expect(time.unit, 'ч');
    expect(j.xp, greaterThan(0));
    expect(j.medals.map((m) => m.id).toSet().length, 52);
  });
  test('live milestones do not award completed rides and never repeat', () {
    final tracker = LiveAchievementSession([]);
    final live = tracker.check(ride(5));
    expect(live.map((m) => m.badge.title), contains('5 км пути'));
    expect(live.any((m) => m.badge.title == 'Первый заезд'), isFalse);
    expect(tracker.check(ride(5)), isEmpty);
    expect(
      tracker.check(ride(5), completed: true).map((m) => m.badge.title),
      contains('Первый заезд'),
    );
  });
  test('restored workout remembers announced milestones and catalog titles cannot collide', () {
    final first = LiveAchievementSession([])..check(ride(5));
    final restored = LiveAchievementSession([])..remember(first.announcedIds);
    expect(restored.check(ride(5)), isEmpty);
    AchievementsService.catalog = [
      const CatalogAchievement({
        'id': 'custom-five',
        'title': '5 км пути',
        'icon': '🏅',
        'description': 'Другая награда',
        'metric': 'rides',
        'threshold': 20,
      }),
    ];
    final medals = AchievementJourney([ride(5)]).medals
        .where((m) => m.badge.title == '5 км пути')
        .toList();
    expect(medals.map((m) => m.id).toSet(), {
      'builtin:5 км пути',
      'catalog:custom-five',
    });
    expect(
      medals.firstWhere((m) => m.id == 'catalog:custom-five').category,
      'Регулярность',
    );
  });
  test('historical awards are not announced as new and discarded progress is not persisted', () {
    final history = [ride(10, minutes: 0)];
    expect(LiveAchievementSession(history).check(ride(1, minutes: 0)), isEmpty);
    final before = AchievementJourney([]);
    LiveAchievementSession([]).check(ride(100));
    expect(AchievementJourney([]).xp, before.xp);
    expect(before.rank, JourneyRank.all.first);
    expect(before.nextRank, JourneyRank.all[1]);
    expect(before.rankProgress, 0);
  });
  testWidgets('medals and title ladder fit a narrow phone with large text', (
    tester,
  ) async {
    final originalErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      FlutterError.dumpErrorToConsole(details, forceReport: true);
      originalErrorHandler?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalErrorHandler);
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 800),
            textScaler: TextScaler.linear(1.5),
          ),
          child: AchievementHub(
            journey: AchievementJourney([ride(12)]),
            onRefresh: () async {},
            records: const Text('Рекорды'),
            statistics: const Text('Статистика'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ваш путь'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Титулы'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Титулы'));
    await tester.tap(find.text('Титулы'));
    await tester.pumpAndSettle();
    expect(find.text('Титулы пути'), findsOneWidget);
    expect(find.text('Легенда PulsePath'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('achievement banner expires and supports dismissal', (
    tester,
  ) async {
    final controller = AchievementBannerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RideAchievementBanner(controller: controller)),
      ),
    );
    controller.show(LiveAchievementSession([]).check(ride(5)));
    await tester.pumpAndSettle();
    expect(find.text('НОВЫЙ РУБЕЖ'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('НОВЫЙ РУБЕЖ'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('render achievement preview', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = GlobalKey();
    const previewFont = 'PreviewSans';
    if (const bool.fromEnvironment('RENDER_PREVIEW')) {
      await tester.runAsync(() async {
        final loader = FontLoader(previewFont);
        final bytes = await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
        for (final font in {
          'PreviewEmoji': 'C:/Windows/Fonts/seguiemj.ttf',
          'MaterialIcons': 'C:/src/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        }.entries) {
          final fontLoader = FontLoader(font.key);
          final data = await File(font.value).readAsBytes();
          fontLoader.addFont(Future.value(ByteData.sublistView(data)));
          await fontLoader.load();
        }
      });
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: const bool.fromEnvironment('RENDER_PREVIEW')
                ? previewFont
                : null,
            fontFamilyFallback: const ['PreviewEmoji'],
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF183D34),
            ),
            useMaterial3: true,
          ),
          home: AchievementHub(
            journey: AchievementJourney([ride(12)]),
            onRefresh: () async {},
            records: const SizedBox(),
            statistics: const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('RENDER_PREVIEW')) {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/previews/achievements_1_10_9.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
