import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/ride_media.dart';
import 'package:pulsepath/models/track_media_groups.dart';
import 'package:pulsepath/widgets/track_media_thumbnail.dart';

SharedRideMedia clip(int i) => SharedRideMedia(
  id: 'v$i',
  pointIndex: i,
  kind: RideMediaKind.video,
  reference: 'ride:owner/v$i.mp4',
  caption: 'Место съёмки $i с длинной подписью',
);
void main() {
  test('Nearby media group at zoom; invalid anchors are not put on map', () {
    final points = [
      const LatLng(55, 37),
      const LatLng(55.00001, 37),
      const LatLng(55.002, 37),
    ];
    final groups = groupTrackMedia([0, 1, 2, 999], points, (i) => i, 18);
    expect(groups, [
      [0, 1],
      [2],
    ]);
    expect(
      groupTrackMedia([0, 1], points, (i) => i, 22).expand((g) => g).toList(),
      [0, 1],
    );
  });
  test(
    'Poster survives route reindexing and rejects another owner or media id',
    () {
      final row = {
        ...clip(0).toJson(),
        'poster_reference': 'ride:owner/v0-preview.png',
      };
      final media = SharedRideMedia.tryParse(row)!;
      expect(media.at(8).posterReference, 'ride:owner/v0-preview.png');
      expect(
        SharedRideMedia.tryParse({
          ...row,
          'poster_reference': 'ride:other/v0-preview.png',
        }),
        isNull,
      );
      expect(
        SharedRideMedia.tryParse({
          ...row,
          'poster_reference': 'ride:owner/v1-preview.png',
        }),
        isNull,
      );
      expect(SharedRideMedia.tryParse(clip(0).toJson()), isNotNull);
    },
  );
  testWidgets(
    'Strip has select/open separately, follows selected marker, fits 320 with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final items = List.generate(8, clip);
      String? chosen, opened;
      Widget screen(String? selected) => MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: TrackMediaStrip(
            shared: items,
            selectedId: selected,
            onSelect: (id) => chosen = id,
            onOpen: (id) => opened = id,
          ),
        ),
      );
      await tester.pumpWidget(screen(null));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TrackMediaThumbnail).first);
      await tester.pump();
      expect(chosen, 'v0');
      expect(opened, isNull);
      await tester.tap(find.text('Открыть').first);
      await tester.pump();
      expect(opened, 'v0');
      await tester.pumpWidget(screen('v7'));
      await tester.pumpAndSettle();
      final last = find.byWidgetPredicate(
        (w) => w is TrackMediaThumbnail && w.shared?.id == 'v7',
      );
      expect(last, findsOneWidget);
      expect(tester.getRect(last).left, lessThan(320));
      expect(tester.takeException(), isNull);
    },
  );
}
