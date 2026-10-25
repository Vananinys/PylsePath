import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/widgets/map_sticker_flight.dart';

MapStickerEffect effect(String id, {bool rain = false}) => MapStickerEffect(
  id: id,
  point: const LatLng(55, 83),
  emoji: '🔥',
  origin: const Offset(50, 500),
  rain: rain,
);

Widget scene(
  MapController map,
  ValueNotifier<List<MapStickerEffect>> effects,
  void Function(String) complete, {
  bool reduced = false,
  bool overlay = true,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: map,
            options: const MapOptions(
              initialCenter: LatLng(55, 83),
              initialZoom: 16,
            ),
            children: const [],
          ),
          if (overlay)
            Positioned.fill(
              child: MapStickerFlightOverlay(
                effects: effects,
                mapController: map,
                onEffectCompleted: complete,
              ),
            ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'rapid bursts overlap and removing a finished flight preserves its neighbours',
    (tester) async {
      final map = MapController();
      final effects = ValueNotifier<List<MapStickerEffect>>([]);
      final completed = <String>[];
      void complete(String id) {
        completed.add(id);
        effects.value = effects.value.where((e) => e.id != id).toList();
      }

      await tester.pumpWidget(scene(map, effects, complete));
      effects.value = [effect('first', rain: true)];
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      effects.value = [...effects.value, effect('second', rain: true)];
      await tester.pump();
      await tester.pump();
      final secondAnimation = find.descendant(
        of: find.byKey(const ValueKey('second')),
        matching: find.byType(TweenAnimationBuilder<double>),
      );
      final secondState = tester.state(secondAnimation);
      for (var i = 0; i < 10; i++) {
        effects.value = [...effects.value, effect('extra-$i')];
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(StickerFlight), findsNWidgets(12));
      expect(tester.state(secondAnimation), same(secondState));
      await tester.pump(const Duration(milliseconds: 1716));
      expect(completed, ['first']);
      expect(find.byKey(const ValueKey('first')), findsNothing);
      expect(tester.state(secondAnimation), same(secondState));
      await tester.pumpAndSettle();
      expect(completed.length, 12);
      expect(completed.toSet().length, 12);
      expect(effects.value, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      effects.dispose();
      map.dispose();
    },
  );

  testWidgets(
    'map motion updates the destination without restarting a flight',
    (tester) async {
      final map = MapController();
      final effects = ValueNotifier<List<MapStickerEffect>>([]);
      final completed = <String>[];
      void complete(String id) {
        completed.add(id);
        effects.value = effects.value.where((e) => e.id != id).toList();
      }

      await tester.pumpWidget(scene(map, effects, complete));
      effects.value = [effect('a')];
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      final animation = find.descendant(
        of: find.byKey(const ValueKey('a')),
        matching: find.byType(TweenAnimationBuilder<double>),
      );
      final state = tester.state(animation);
      map.move(const LatLng(55.001, 83.001), 17);
      await tester.pump();
      expect(tester.state(animation), same(state));
      await tester.pump(const Duration(milliseconds: 1216));
      await tester.pump();
      expect(completed, ['a']);
      expect(effects.value, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      effects.dispose();
      map.dispose();
    },
  );

  testWidgets(
    'reduced animations clean up on completion and hiding clears pending flights',
    (tester) async {
      final map = MapController();
      final effects = ValueNotifier<List<MapStickerEffect>>([]);
      void complete(String id) {
        effects.value = effects.value.where((e) => e.id != id).toList();
      }

      await tester.pumpWidget(scene(map, effects, complete, reduced: true));
      effects.value = [effect('short')];
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 466));
      await tester.pump();
      expect(effects.value, isEmpty);
      effects.value = [effect('hidden')];
      await tester.pump();
      await tester.pumpWidget(scene(map, effects, complete, overlay: false));
      await tester.pump();
      expect(effects.value, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      effects.dispose();
      map.dispose();
    },
  );
}
