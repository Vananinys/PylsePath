import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/models/bike_equipment.dart';
import 'package:pulsepath/models/bike_setup.dart';
import 'package:pulsepath/models/vehicle.dart';
import 'package:pulsepath/widgets/bike_diagram.dart';
import 'package:pulsepath/services/garage_maintenance_reminders.dart';
import 'package:pulsepath/widgets/bike_workshop_scene.dart';

void main() {
  test(
    'first service threshold wins; unknown legacy hours never invent wear',
    () {
      const p = BikePart(
        id: 'fork',
        name: 'Вилка',
        intervalKm: 1000,
        lastServiceKm: 100,
        intervalHours: 50,
        lastServiceHours: 10,
        installedHours: 0,
      );
      expect(p.due(200, totalHours: 59), isFalse);
      expect(p.due(200, totalHours: 60), isTrue);
      expect(p.due(1100, totalHours: 20), isTrue);
      expect(p.usedHours(40), 30);
      expect(p.lifetimeHours(40), 40);
      final restored = BikePart.fromJson(p.toJson());
      expect(restored.lastServiceHours, 10);
      expect(restored.serviceStatus(200, 60), 'Пора проверить');
      final legacy = BikePart.fromJson({
        'id': 'chain',
        'name': 'Цепь',
        'interval_hours': 50,
      });
      expect(legacy.usedHours(500), isNull);
      expect(legacy.due(0, totalHours: 500), isFalse);
      expect(legacy.serviceStatus(0, 500), contains('укажите отметку часов'));
    },
  );
  test('hours belong to the vehicle and reminder switch persists', () {
    final v = Vehicle.fromRow({
      'id': 'bike',
      'user_id': 'owner',
      'title': 'МТБ',
      'recorded_hours': 70,
      'maintenance': [
        const BikePart(
          id: 'fork',
          name: 'Вилка',
          intervalHours: 50,
          lastServiceHours: 0,
        ).toJson(),
      ],
    });
    expect(GarageMaintenanceReminders.dueLines([v]), ['МТБ: Вилка']);
    final silent = v.copyWith(
      drivetrain: const BikeDrivetrain(
        setup: BikeSetup(diagram: 'enduro', maintenanceReminders: false),
      ),
    );
    final roundtrip = Vehicle.fromRow({
      ...silent.toRow(userId: 'owner'),
      'recorded_hours': 70,
    });
    expect(roundtrip.drivetrain!.setup.diagram, 'enduro');
    expect(GarageMaintenanceReminders.dueLines([roundtrip]), isEmpty);
  });
  test('all four diagrams fit their board and near components can be disambiguated', () {
    const parts = [
      BikePart(id: 'chain', name: 'Цепь'),
      BikePart(id: 'cranks', name: 'Шатуны'),
      BikePart(id: 'cassette', name: 'Кассета'),
    ];
    for (final kind in ['road', 'gravel', 'hardtail', 'enduro']) {
      // The overlap assertion needs a cassette; auto without configured gears
      // intentionally renders a single-speed drivetrain with no cassette.
      final g = BikeDiagramGeometry(
        kind,
        setup: const BikeSetup(transmission: 'geared'),
      );
      expect(
        g.path('front_tyre').getBounds().right + g.tyreWidth / 2,
        lessThan(1000),
      );
      expect(
        g.path('rear_tyre').getBounds().left - g.tyreWidth / 2,
        greaterThan(0),
      );
      expect(
        g.hit(const Offset(350, 425), parts, 40).map((p) => p.id),
        contains('chain'),
      );
      expect(g.hit(g.rear, parts, 50).length, greaterThan(1));
    }
    expect(
      BikeDiagramGeometry('enduro').head,
      isNot(BikeDiagramGeometry('hardtail').head),
    );
  });
  testWidgets('diagram choice and large text remain usable on narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: BikeWorkshopScene(
                parts: const [],
                odometer: 0,
                setup: const BikeSetup(diagram: 'enduro'),
                onSelect: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('МТБ · эндуро'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
