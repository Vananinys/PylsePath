import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/models/bike_equipment.dart';
import 'package:pulsepath/models/vehicle.dart';
import 'package:flutter/material.dart';
import 'package:pulsepath/services/garage_service.dart';
import 'package:pulsepath/screens/vehicle_detail_screen.dart';
import 'package:pulsepath/widgets/gear_advisor_card.dart';

void main() {
  testWidgets('editing an old part does not invent an inspection date', (
    tester,
  ) async {
    const vehicle = Vehicle(
      id: 'bike',
      userId: 'owner',
      name: 'Велосипед',
      transportType: 'mountainBiking',
      parts: [BikePart(id: 'chain', name: 'Цепь')],
    );
    final service = _GarageFake(vehicle);
    await tester.pumpWidget(
      MaterialApp(
        home: VehicleDetailScreen(vehicle: vehicle, service: service),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Открыть: Цепь'), findsOneWidget);
    final settings = find.text('Настроить');
    await tester.ensureVisible(settings);
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(find.text('Указать дату последней проверки'), findsOneWidget);
    final days = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.labelText == 'Интервал по времени, дней',
    );
    await tester.enterText(days, '30');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(
      find.text('Укажите дату последней проверки для календарного интервала'),
      findsOneWidget,
    );
    await tester.enterText(days, '0');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(service.vehicle.parts.single.serviceDate, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'owner can persist visibility; public detail hides private controls',
    (tester) async {
      const v = Vehicle(
        id: 'bike',
        userId: 'owner',
        name: 'Test bike',
        transportType: 'mountainBiking',
        totalDistance: 500,
        parts: [
          BikePart(
            id: 'chain',
            name: 'Цепь',
            intervalKm: 300,
            lastServiceKm: 100,
          ),
        ],
      );
      final service = _GarageFake(v);
      await tester.pumpWidget(
        MaterialApp(
          home: VehicleDetailScreen(vehicle: v, service: service),
        ),
      );
      await tester.pumpAndSettle();
      final toggle = find.widgetWithText(
        SwitchListTile,
        'Показывать в публичном профиле',
      );
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(service.vehicle.isPublic, isTrue);
      await tester.pumpWidget(
        const MaterialApp(
          home: VehicleDetailScreen(vehicle: v, readOnly: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Состояние и обслуживание'), findsNothing);
      expect(find.text('Показывать в публичном профиле'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('gear advisor fits narrow phone and changes planned tempo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const v = Vehicle(
      id: 'bike',
      userId: 'owner',
      name: 'Test bike',
      transportType: 'mountainBiking',
      drivetrain: BikeDrivetrain(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GearAdvisorCard(
            vehicle: v,
            speedKmh: 0,
            planning: true,
            onConfigure: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Спереди'), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  test('gear recommendation obeys distance per pedal revolution', () {
    const bike = BikeDrivetrain(
      front: [32],
      rear: [32, 24, 16, 12],
      circumference: 2,
      targetCadence: 80,
    );
    final suggestion = bike.suggest(19.2)!;
    expect(suggestion.frontTeeth, 32);
    expect(suggestion.rearTeeth, 16);
    expect(suggestion.cadence, closeTo(80, 0.0001));
    expect(bike.suggest(0), isNull);
    expect(bike.suggest(double.nan), isNull);
  });
  test('21 speed recommendations avoid extreme chain crossovers', () {
    const bike = BikeDrivetrain();
    expect(bike.speeds, 21);
    for (final speed in [3.0, 8.0, 15.0, 25.0, 40.0, 60.0]) {
      final s = bike.suggest(speed)!;
      expect(s.front == 1 && s.rear >= 6, isFalse);
      expect(s.front == 3 && s.rear <= 2, isFalse);
    }
  });
  test('maintenance uses saved odometer baseline and configured interval', () {
    const part = BikePart(
      id: 'chain',
      name: 'Chain',
      lastServiceKm: 500,
      intervalKm: 300,
    );
    expect(part.usedKm(650), 150);
    expect(part.usedFraction(650), .5);
    expect(part.due(801), isTrue);
    expect(part.usedKm(400), 0);
    expect(const BikePart(id: 'a', name: 'A').usedFraction(100), isNull);
    final serviced = part.copyWith(
      lastServiceKm: 801,
      history: [
        {'action': 'Замена', 'km': 801},
      ],
    );
    final restored = BikePart.fromJson(serviced.toJson());
    expect(restored.usedKm(820), 19);
    expect(restored.history.single['action'], 'Замена');
  });
  test('garage parser retains public visibility, parts and drivetrain', () {
    final v = Vehicle.fromRow({
      'id': 'bike',
      'user_id': 'owner',
      'title': 'Bicycle',
      'is_public': true,
      'is_ebike': true,
      'maintenance': [
        const BikePart(id: 'a', name: 'A', intervalKm: 500).toJson(),
      ],
      'drivetrain': const BikeDrivetrain().toJson(),
    });
    expect(v.isPublic, isTrue);
    expect(v.copyWith(name: 'Renamed').parts.single.intervalKm, 500);
    expect(v.copyWith(name: 'Renamed').drivetrain!.speeds, 21);
    expect(v.isEbike, isTrue);
    expect(v.copyWith(isPublic: false).isPublic, isFalse);
  });
}

class _GarageFake extends GarageService {
  _GarageFake(this.vehicle);
  Vehicle vehicle;
  @override
  Future<Vehicle> fetchVehicle(String vehicleId) async => vehicle;
  @override
  Future<Vehicle> saveEquipment(Vehicle value) async {
    vehicle = value;
    return value;
  }
}
