import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/widgets/pre_ride_widget.dart';
import 'package:pulsepath/widgets/group_start_choice.dart';
import 'package:pulsepath/services/group_ride_service.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'Preparation remains usable with large text (${dark ? 'dark' : 'light'})',
      (t) async {
        t.view.physicalSize = const Size(360, 800);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        var mode = SportMode.vehicle, started = 0, selected = 0;
        final group = GroupRideService.forTesting();
        addTearDown(group.dispose);
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(360, 800),
                textScaler: TextScaler.linear(2.0),
              ),
              child: Scaffold(
                body: SizedBox(
                  height: 760,
                  child: StatefulBuilder(
                    builder: (context, update) => PreRideWidget(
                      selectedVehicle: null,
                      onSelectVehicle: () => selected++,
                      autoPauseEnabled: false,
                      onAutoPauseChanged: (_) {},
                      sportMode: mode,
                      onSportModeChanged: (value) => update(() => mode = value),
                      onStartRide: () => started++,
                      onCollapse: () {},
                      groupChoice: GroupStartChoice(
                        service: group,
                        selectedRoomId: null,
                        onChanged: (_) {},
                        onManage: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.tap(find.text('Начать тренировку'));
        expect(started, 1);
        final vehicle = find.text('Без привязки к технике');
        await t.ensureVisible(vehicle);
        await t.tap(vehicle);
        expect(selected, 1);
        await t.ensureVisible(find.text('Пешком и бег'));
        await t.tap(find.text('Пешком и бег'));
        await t.pumpAndSettle();
        expect(mode, SportMode.walking);
        expect(t.takeException(), isNull);
      },
    );
  }
}
