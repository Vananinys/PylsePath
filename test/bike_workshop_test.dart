import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/models/bike_equipment.dart';
import 'package:pulsepath/models/bike_setup.dart';
import 'package:pulsepath/models/vehicle.dart';
import 'package:pulsepath/models/workout_details.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/screens/vehicle_detail_screen.dart';
import 'package:pulsepath/services/garage_service.dart';
import 'package:pulsepath/services/cycling_energy.dart';
import 'package:pulsepath/services/cycling_power.dart';
import 'package:pulsepath/widgets/bike_workshop_scene.dart';
import 'package:pulsepath/widgets/bike_workshop_editors.dart';

import 'workout_training_test.dart' show TrainingClock;

const bicycle = Vehicle(
  id: 'bike',
  userId: 'owner',
  name: 'Мой велосипед',
  transportType: 'roadCycling',
  weightKg: 9,
  totalDistance: 1000,
  drivetrain: BikeDrivetrain(
    setup: BikeSetup(cargoKg: 8, posture: 'sport', tyres: 'slick'),
  ),
  parts: [
    BikePart(
      id: 'chain',
      name: 'Цепь',
      lastServiceKm: 800,
      installedKm: 200,
      priorKm: 50,
      intervalKm: 300,
    ),
  ],
);

class WorkshopGarage extends GarageService {
  Vehicle value = bicycle;
  @override
  Future<Vehicle> fetchVehicle(String vehicleId) async => value;
  @override
  Future<Vehicle> saveEquipment(Vehicle vehicle) async {
    value = vehicle;
    return value;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkoutHistoryRepository.resetInstancesForTesting();
  });
  test(
    'legacy equipment and new component passport survive JSON and gear changes',
    () {
      final row = bicycle.toRow(userId: 'owner');
      final loaded = Vehicle.fromRow({...row, 'id': 'bike'});
      expect(loaded.parts.single.lifetimeKm(1000), 850);
      expect(loaded.parts.single.usedKm(1000), 200);
      expect(loaded.drivetrain!.setup.cargoKg, 8);
      final gear = BikeDrivetrain(
        front: const [32],
        rear: const [32, 16],
        setup: loaded.drivetrain!.setup,
      );
      expect(BikeDrivetrain.fromJson(gear.toJson()).setup.posture, 'sport');
      expect(
        BikeDrivetrain.fromJson({
          'front': [32],
          'rear': [20],
        }).setup.cargoKg,
        0,
      );
      final legacy = BikePart.fromJson({
        'id': 'fork',
        'name': 'Вилка',
        'last_km': 400,
      });
      expect(legacy.lifetimeKm(1000), 600);
      expect(legacy.template.category, 'Подвеска');
    },
  );
  test(
    'bike setup affects road-load estimate and invalid settings are rejected',
    () {
      final baseline = CyclingPower.estimate(
        speedKmh: 25,
        riderKg: 70,
        bikeKg: 12,
      )!;
      expect(
        CyclingPower.estimate(
          speedKmh: 25,
          riderKg: 70,
          bikeKg: 12,
          cargoKg: 20,
        ),
        greaterThan(baseline),
      );
      expect(
        CyclingPower.estimate(
          speedKmh: 25,
          riderKg: 70,
          bikeKg: 12,
          cda: .32,
          crr: .005,
        ),
        lessThan(baseline),
      );
      expect(
        CyclingPower.estimate(
          speedKmh: 25,
          riderKg: 70,
          bikeKg: 12,
          cargoKg: double.nan,
        ),
        isNull,
      );
      expect(
        BikeSetup.fromJson({'cargo_kg': double.nan, 'posture': 'invalid'})
            .cargoKg,
        0,
      );
    },
  );
  test('calories use rider mass, speed and chosen motor assistance', () {
    final normal = CyclingEnergy.rate(riderKg: 70, speedKmh: 20);
    expect(normal, closeTo(588, .001));
    expect(CyclingEnergy.rate(riderKg: 140, speedKmh: 20), normal * 2);
    expect(CyclingEnergy.rate(riderKg: 70, speedKmh: 30), greaterThan(normal));
    expect(
      CyclingEnergy.rate(
        riderKg: 70,
        speedKmh: 20,
        ebike: true,
        setup: const BikeSetup(assistance: 'high'),
      ),
      lessThan(normal),
    );
    expect(CyclingEnergy.rate(riderKg: double.nan, speedKmh: 20), 0);
  });
  test(
    'saved workout freezes equipment and calories exclude manual pause',
    () async {
      final clock = TrainingClock();
      final controller = MapNavigationController(activeClock: clock);
      controller.setPreRideVehicle(bicycle);
      controller.setCalorieWeightKg(80);
      controller.startWorkout();
      clock.advance(60);
      controller.pauseWorkout();
      final before = controller.workoutCalories;
      expect(before, greaterThan(0));
      clock.advance(900);
      expect(controller.workoutCalories, before);
      controller.setPreRideVehicle(bicycle.copyWith(name: 'Другой'));
      controller.resumeWorkout();
      clock.advance(60);
      final saved = await controller.finishAndSaveWorkout();
      expect(saved!.durationSeconds, 120);
      expect(saved.calories, closeTo(before * 2, .0001));
      final energy = WorkoutDetails.fromJson(saved.workoutDetails.toJson())
          .energyModel!;
      expect(energy['vehicle_title'], bicycle.name);
      expect(energy['component_names'], ['Цепь']);
      expect(energy['active_ms'], 120000);
      expect(saved.workoutDetails.powerModel!['cargo_kg'], 8);
      expect(saved.workoutDetails.powerModel!['cda'], .32);
      controller.dispose();
    },
  );
  testWidgets('scene selects components, filters and zooms on narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BikeWorkshopScene(
            parts: bicycle.parts,
            odometer: 1000,
            setup: bicycle.drivetrain!.setup,
            onSelect: (id) => selected = id,
          ),
        ),
      ),
    );
    final board = find.byKey(const ValueKey('bike-diagram-target'));
    final origin = tester.getTopLeft(board), size = tester.getSize(board);
    await tester.tapAt(origin + Offset(size.width * .35, size.height * .63));
    expect(selected, 'chain');
    await tester.tap(find.byTooltip('Увеличить'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!
          .value
          .getMaxScaleOnAxis(),
      greaterThan(1),
    );
    await tester.tap(find.byTooltip('Сбросить масштаб'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Колёса'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Колёса'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'part service keeps lifetime, replacement starts a new component with history',
    (tester) async {
      final service = WorkshopGarage();
      await tester.pumpWidget(
        MaterialApp(
          home: VehicleDetailScreen(vehicle: bicycle, service: service),
        ),
      );
      await tester.pumpAndSettle();
      final action = find.widgetWithText(FilledButton, 'Обслужено');
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Записать'));
      await tester.pumpAndSettle();
      expect(service.value.parts.single.lifetimeKm(1000), 850);
      expect(service.value.parts.single.usedKm(1000), 0);
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Замена').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Записать'));
      await tester.pumpAndSettle();
      expect(service.value.parts.single.lifetimeKm(1000), 0);
      expect(service.value.parts.single.history.length, 2);
      expect(service.value.parts.single.history.first['component_km'], 850);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'catalog cancel creates no blank component and passport validates mileage',
    (tester) async {
      BikePart? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  saved = await editBikePartSpecifications(
                    context,
                    const BikePart(
                      id: 'new',
                      name: 'Покрышка',
                      installedKm: 1000,
                    ),
                    1000,
                  );
                },
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      final input = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.labelText == 'Одометр велосипеда при установке, км',
      );
      await tester.enterText(input, '2000');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Пробег установки не может'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
