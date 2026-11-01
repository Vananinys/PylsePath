import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/widgets/activity_trail_layer.dart';
import 'package:pulsepath/models/live_trail_style.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/data/trail_appearance.dart';
void main() {
 test('Clipping retains geographic stamp identity and left/right order', () {
  final segments = [[const Offset(0, 0), const Offset(1000, 0)]];
  final all = sampleTrail(segments, 28, const Rect.fromLTWH(0,-10,1000,20));
  final cropped = sampleTrail(segments, 28, const Rect.fromLTWH(200,-10,300,20));
  for (final stamp in cropped) {
   final original = all.singleWhere((s) => s.identity == stamp.identity);
   expect(stamp.position, original.position); expect(stamp.alternate,original.alternate);
  }
 });
 testWidgets('Pulse has an actual repaint animation and respects reduced motion', (tester) async {
  final appearance=TrailAppearance();
  await tester.pumpWidget(MaterialApp(home: TrailStylePreview(appearance:appearance,activity:ActivityType.hiking,effect:MotionEffect.pulse)));
  final first=tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((w)=>w.painter).whereType<TrailPainter>().single;
  expect(first.animation,isNotNull);
  await tester.pump(const Duration(milliseconds:400)); expect(first.animation!.value,greaterThan(0));
  await tester.pumpWidget(MaterialApp(home: MediaQuery(data:const MediaQueryData(disableAnimations:true), child:TrailStylePreview(appearance:appearance,activity:ActivityType.hiking,effect:MotionEffect.pulse))));
  final reduced=tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((w)=>w.painter).whereType<TrailPainter>().single;
  expect(reduced.animation,isNull);
  await tester.pumpWidget(const SizedBox()); appearance.dispose();
 });
}
