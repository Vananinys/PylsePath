import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/widgets/community_composer_frame.dart';
import 'package:pulsepath/models/saved_route.dart';

void main() {
  testWidgets('editor actions remain reachable with keyboard and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var published = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            viewInsets: const EdgeInsets.only(bottom: 280),
          ),
          child: child!,
        ),
        home: CommunityComposerFrame(
          title: const Text('Новая публикация'),
          onClose: () {},
          content: const SingleChildScrollView(child: TextField(maxLines: 5)),
          actions: [
            FilledButton(
              onPressed: () => published = true,
              child: const Text('Опубликовать'),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('Опубликовать'));
    expect(published, isTrue);
    expect(
      tester.getRect(find.text("Опубликовать")).bottom,
      lessThanOrEqualTo(520),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'ride choices stay in a separate list and cancellation preserves selection',
    (tester) async {
      final rides = List.generate(
        10,
        (i) => SavedRoute(
          title: 'Заезд $i',
          distance: '10 км',
          duration: '40 мин',
          surfaceSummary: '',
          finishPoint: const LatLng(0, 0),
          routePoints: const [],
          activityType: ActivityType.cycling,
        ),
      );
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommunityRidePicker(
              rides: rides,
              selectedId: null,
              onChanged: (id) => selected = id,
            ),
          ),
        ),
      );
      expect(find.text('Заезд 0'), findsNothing);
      await tester.tap(find.text('Прикрепить заезд'));
      await tester.pumpAndSettle();
      expect(find.text('Заезд 0'), findsOneWidget);
      await tester.tap(find.text('Заезд 0'));
      await tester.pumpAndSettle();
      expect(selected, rides.first.localId);
      expect(tester.takeException(), isNull);
    },
  );
}
