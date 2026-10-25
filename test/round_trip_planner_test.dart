import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/widgets/round_trip_planner.dart';

void main() {
  testWidgets('Loop planner fits a small phone and returns the selected route', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    RoundTripRequest? request;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          request = await showModalBottomSheet<RoundTripRequest>(
            context: context, isScrollControlled: true,
            builder: (_) => const RoundTripPlanner(activity: ActivityType.cycling),
          );
        },
        child: const Text('Открыть'),
      ),
    ))));
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Построить круг'));
    await tester.tap(find.text('Построить круг'));
    await tester.pumpAndSettle();
    expect(request?.distanceKm, 20);
    expect(request?.activity, ActivityType.cycling);
    expect(request?.bearing, 0);
    expect(tester.takeException(), isNull);
  });
}
