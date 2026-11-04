import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/widgets/route_drawing_layer.dart';

void main() {
  testWidgets(
    'Held and slow touch stays with drawing, then map gestures return',
    (tester) async {
      final map = MapController();
      addTearDown(map.dispose);
      List<LatLng>? stroke;
      var longPresses = 0;
      Future<void> show(bool drawing) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FlutterMap(
                mapController: map,
                options: MapOptions(
                  initialCenter: const LatLng(55, 83),
                  initialZoom: 14,
                  onLongPress: (_, __) => longPresses++,
                ),
                children: [
                  if (drawing)
                    RouteDrawingLayer(onStroke: (raw, smooth) => stroke = raw),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(true);
      final center = map.camera.center;
      final gesture = await tester.startGesture(
        const Offset(100, 200),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 700));
      for (var i = 0; i < 30; i++) {
        await gesture.moveBy(const Offset(4, 1));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(stroke, isNotNull);
      expect(stroke!.length, greaterThan(10));
      expect(map.camera.center, center);
      expect(longPresses, 0);
      await show(false);
      await tester.drag(find.byType(FlutterMap), const Offset(100, 0));
      await tester.pumpAndSettle();
      expect(map.camera.center, isNot(center));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
