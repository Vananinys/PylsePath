import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, MethodCall;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/models/route_edit_state.dart';
import 'package:pulsepath/models/ride_media.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/shared_route.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/data/ride_media_repository.dart';
import 'package:pulsepath/data/navigation_preferences.dart';
import 'package:pulsepath/screens/route_builder_screen.dart';
import 'package:pulsepath/screens/ride_media_screen.dart';
import 'package:pulsepath/utils/ride_media_export.dart';

const a = LatLng(55, 37), b = LatLng(55.001, 37), c = LatLng(55.002, 37);
const d = LatLng(56, 38), e = LatLng(56.001, 38);
RideMedia media(String id, int index) => RideMedia(
  id: id,
  pointIndex: index,
  kind: RideMediaKind.photo,
  localPath: '/private/$id.jpg',
  createdAt: DateTime.utc(2026),
  caption: 'Место',
);
SharedRideMedia share(String id, int index) => SharedRideMedia(
  id: id,
  pointIndex: index,
  kind: RideMediaKind.photo,
  reference: 'ride:owner/$id.png',
  caption: 'Вид',
);
SavedRoute ride(List<LatLng> points) => SavedRoute(
  localId: 'ride',
  title: 'Заезд',
  distance: '1 км',
  duration: '10 мин',
  finishPoint: points.last,
  routePoints: points,
  activityType: ActivityType.cycling,
  surfaceSummary: '',
  calories: 500,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('Editing creates independent immutable geometry', () {
    final original = RouteEditState([a, b, c]);
    final edited = original.move(1, d).insert(1, e).remove(0);
    expect(original.points, [a, b, c]);
    expect(edited.points, [d, e, c]);
    expect(() => original.points.add(d), throwsUnsupportedError);
  });
  test('Distance excludes GPS gaps', () {
    final state = RouteEditState([a, b, d, e], starts: [0, 2]);
    const distance = Distance();
    expect(state.meters, closeTo(distance(a, b) + distance(d, e), .001));
    expect(state.meters, lessThan(500));
  });
  test('Reverse and trim retain gaps including singleton segments', () {
    final state = RouteEditState([a, b, c, d, e], starts: [0, 2, 3]);
    final reverse = state.reversed();
    expect(reverse.points, [e, d, c, b, a]);
    expect(reverse.starts, [0, 2, 3]);
    expect(reverse.reversed().points, state.points);
    final trimmed = state.trim(1, 4);
    expect(trimmed.points, [b, c, d, e]);
    expect(trimmed.starts, [0, 1, 2]);
    expect(trimmed.meters, closeTo(const Distance()(d, e), .001));
  });
  test('Removing a segment start does not join disconnected sections', () {
    final next = RouteEditState([a, b, c, d, e], starts: [0, 2]).remove(2);
    expect(next.starts, [0, 2]);
    expect(next.points, [a, b, d, e]);
    expect(
      next.meters,
      closeTo(const Distance()(a, b) + const Distance()(d, e), .001),
    );
  });
  test('Loop rejects gaps; reordering and control extraction are bounded', () {
    expect(
      () => RouteEditState([a, b, d, e], starts: [0, 2]).closeLoop(),
      throwsFormatException,
    );
    expect(RouteEditState([a, b, c]).closeLoop().points, [a, b, c, a]);
    expect(RouteEditState([a, b, c]).reorder(2, 0).points, [c, a, b]);
    final points = List.generate(100, (i) => LatLng(55 + i * .0001, 37));
    final controls = RouteEditState(points).controlPoints();
    expect(controls.points.length, 10);
    expect(controls.points.first, points.first);
    expect(controls.points.last, points.last);
  });
  test(
    'Planned copy has a new identity and no recorded metrics or remote id',
    () {
      final original = ride([a, b, c]);
      final copy = RouteEditState(original.routePoints)
          .plannedCopy(title: ' Копия ', activity: original.activityType);
      expect(copy.localId, isNot(original.localId));
      expect(copy.remoteId, isNull);
      expect(copy.calories, 0);
      expect(original.calories, 500);
      expect(copy.workoutDetails.samples, isEmpty);
      expect(copy.title, 'Копия');
      expect(copy.durationSeconds, 0);
      expect(
        () =>
            RouteEditState([a])
                .plannedCopy(title: 'a', activity: ActivityType.cycling),
        throwsFormatException,
      );
    },
  );
  test('Geometric edits invalidate estimated road time', () {
    final state = RouteEditState([a, b], estimatedSeconds: 60);
    expect(state.move(1, c).estimatedSeconds, isNull);
    expect(state.reversed().estimatedSeconds, isNull);
  });
  test(
    'Hidden start/finish media excluded and visible anchor preserved exactly',
    () {
      final points = [for (var i = 0; i < 20; i++) LatLng(55 + i * .001, 37)];
      final snapshot = SharedRoute.fromSavedRoute(
        ride(points),
        hideRadiusMeters: 200,
        media: [share('start', 0), share('middle', 10), share('end', 19)],
      );
      expect(snapshot.media.map((m) => m.id), ['middle']);
      expect(snapshot.points[snapshot.media.single.pointIndex], points[10]);
      expect(snapshot.toJson().toString(), isNot(contains('/private/')));
    },
  );
  test('No track means no media or leaked location', () {
    final snapshot = SharedRoute.fromSavedRoute(
      ride([a, b, c]),
      includeTrack: false,
      media: [share('photo', 1)],
    );
    expect(snapshot.points, isEmpty);
    expect(snapshot.media, isEmpty);
  });
  test('Downsampling keeps a selected anchor instead of moving it to a nearby point', () {
    final points = List.generate(5000, (i) => LatLng(50 + i * .00001, 37));
    final snapshot = SharedRoute.fromSavedRoute(
      ride(points),
      media: [share('rare', 217)],
    );
    expect(snapshot.points.length, lessThanOrEqualTo(1200));
    expect(snapshot.points[snapshot.media.single.pointIndex], points[217]);
    expect(
      SharedRoute.tryParse(snapshot.toJson())!.media.single.reference,
      'ride:owner/rare.png',
    );
  });
  test(
    'Malformed, external or out-of-track shared media reject the snapshot',
    () {
      final base = SharedRoute.fromSavedRoute(ride([a, b, c])).toJson();
      for (final bad in [
        {
          ...share('x', 1).toJson(),
          'reference': 'https://example.invalid/a.png',
        },
        {...share('x', 1).toJson(), 'point_index': 99},
        {...share('x', 1).toJson(), 'kind': 'video'},
      ]) {
        expect(
          SharedRoute.tryParse({
            ...base,
            'media': [bad],
          }),
          isNull,
        );
      }
      expect(
        SharedRoute.tryParse({
          ...base,
          'media': [share('x', 1).toJson(), share('x', 2).toJson()],
        }),
        isNull,
      );
      expect(SharedRoute.tryParse(base), isNotNull);
    },
  );
  test('Concurrent media writes preserve all items and another account stays separate', () async {
    String? owner = 'owner';
    final repo = RideMediaRepository(
      'ride',
      owner: owner,
      currentOwner: () => owner,
    );
    await Future.wait([
      for (var i = 0; i < 20; i++)
        RideMediaRepository(
          'ride',
          owner: owner,
          currentOwner: () => owner,
        ).add([media('m$i', 0)], pointCount: 3),
    ]);
    expect((await repo.load()).length, 20);
    await expectLater(
      repo.add([media('extra', 0)], pointCount: 3),
      throwsStateError,
    );
    owner = 'other';
    await expectLater(repo.load(), throwsStateError);
    expect(
      await RideMediaRepository(
        'ride',
        owner: owner,
        currentOwner: () => owner,
      ).load(),
      isEmpty,
    );
  });
  test('Caption and anchor update retain identity and source, and cannot target a missing point', () async {
    final repo = RideMediaRepository('r', owner: 'u', currentOwner: () => 'u');
    final item = media('m', 0);
    await repo.add([item], pointCount: 3);
    await repo.update(item.at(2, ' новая '), pointCount: 3);
    final saved = (await repo.load()).single;
    expect(saved.localPath, item.localPath);
    expect(saved.id, 'm');
    expect(saved.pointIndex, 2);
    expect(saved.caption, 'новая');
    await expectLater(
      repo.update(item.at(4, 'bad'), pointCount: 3),
      throwsStateError,
    );
    expect((await repo.load()).single.pointIndex, 2);
  });
  test(
    'Corrupt media are not replaced by an empty list on write/remove',
    () async {
      SharedPreferences.setMockInitialValues({
        'ride_media_v1_r_u': '{"version":1,"items":[{}]}',
      });
      final prefs = await SharedPreferences.getInstance();
      final repo = RideMediaRepository(
        'r',
        owner: 'u',
        currentOwner: () => 'u',
      );
      final before = prefs.getString('ride_media_v1_r_u');
      await expectLater(
        repo.add([media('m', 0)], pointCount: 2),
        throwsFormatException,
      );
      await expectLater(repo.remove('m'), throwsFormatException);
      expect(prefs.getString('ride_media_v1_r_u'), before);
    },
  );
  testWidgets(
    'Video export invokes metadata-stripping bridge, not original-path upload',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      MethodCall? captured;
      messenger.setMockMethodCallHandler(
        const MethodChannel('pulsepath/ride_media'),
        (call) async {
          captured = call;
          return '/safe/output.mp4';
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('pulsepath/ride_media'),
          null,
        ),
      );
      expect(await exportRideVideo('/private/source.mov'), '/safe/output.mp4');
      expect(captured!.method, 'stripVideoMetadata');
      expect(captured!.arguments, {'path': '/private/source.mov'});
    },
  );
  testWidgets(
    'Photo export re-encodes pixels to PNG without reusing the source bytes',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 8, 4),
          Paint()..color = const Color(0xFFFF0000),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(8, 4);
        final Uint8List original = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        final output = await exportRidePhoto(original);
        final codec = await ui.instantiateImageCodec(output);
        final decoded = (await codec.getNextFrame()).image;
        expect(output.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        expect(decoded.width, 8);
        expect(decoded.height, 4);
        expect((await decoded.toByteData())!.getUint8(0), 255);
        decoded.dispose();
        codec.dispose();
        image.dispose();
        picture.dispose();
      });
    },
  );
  testWidgets(
    'Constructor fits 320px large text and undo restores the empty draft',
    (tester) async {
      final old = NavigationPreferences.instance.cachedMapOnly;
      NavigationPreferences.instance.cachedMapOnly = true;
      addTearDown(() => NavigationPreferences.instance.cachedMapOnly = old);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: const RouteBuilderScreen(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(100, 150));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 точек'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Отменить изменение'));
      await tester.tap(find.byTooltip('Отменить изменение'));
      await tester.pumpAndSettle();
      expect(find.textContaining('0 точек'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Media cannot be attached with no recorded point', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: RideMediaScreen(rideId: 'empty', points: []),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Нужна хотя бы одна'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Фото'),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
