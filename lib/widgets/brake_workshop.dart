import 'package:flutter/material.dart';

import '../data/workout_history_repository.dart';
import '../data/user_scope.dart';
import '../models/bike_equipment.dart';
import '../models/bike_setup.dart';
import '../models/brake_load.dart';
import '../models/saved_route.dart';
import '../models/vehicle.dart';

class BrakeLoadCard extends StatelessWidget {
  const BrakeLoadCard({
    super.key,
    required this.load,
    this.title = 'Разгоны и замедления',
  });
  final BrakeLoad load;
  final String title;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (load.coveredSeconds > 0) ...[
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                Text('Замедления: ${load.slowdowns}'),
                Text('Разгоны: ${load.accelerations}'),
                Text('Замедление: ${load.slowingSeconds.round()} с'),
                Text(
                  'GPS-охват: ${(load.coveredSeconds / 60).toStringAsFixed(1)} мин',
                ),
                if (load.systemMassKg != null)
                  Text(
                    'Энергия замедлений: ${load.kineticKj.toStringAsFixed(1)} кДж',
                  ),
              ],
            ),
            if (load.massAssumed)
              const Text(
                'Для части расчёта масса велосипеда принята 15 кг. '
                'Уточните её в гараже для следующих заездов.',
              ),
          ] else
            const Text(
              'Пока нет подходящих GPS-данных. Учёт ведётся в новых '
              'велозаездах при достаточно частых и точных измерениях скорости.',
            ),
          const SizedBox(height: 8),
          const Text(
            'Замедления распознаются по GPS. Энергия — потеря энергии движения, '
            'часть которой уходит на воздух, качение и подъём. Это не измерение работы '
            'тормозов или процента износа. Разгоны сами по себе не изнашивают колодки. '
            'Торможение с постоянной скоростью на спуске и короткие события могут не учитываться. '
            'Распределение нагрузки между колёсами неизвестно.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class BrakeWorkshop extends StatefulWidget {
  const BrakeWorkshop({
    super.key,
    required this.vehicle,
    required this.onConfigure,
    required this.onAddParts,
    required this.busy,
    this.selected,
  });
  final Vehicle vehicle;
  final VoidCallback onConfigure, onAddParts;
  final bool busy;
  final BikePart? selected;
  @override
  State<BrakeWorkshop> createState() => _BrakeWorkshopState();
}

class _BrakeWorkshopState extends State<BrakeWorkshop> {
  late Future<List<SavedRoute>> _rides = _load();
  Future<List<SavedRoute>> _load() async {
    final uid = UserScope.currentUserId();
    if (uid != widget.vehicle.userId) return [];
    final rows = await WorkoutHistoryRepository().getWorkoutHistory();
    if (UserScope.currentUserId() != uid) return [];
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vehicle,
        setup = widget.vehicle.drivetrain?.setup ?? const BikeSetup();
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('Тормоза: комплектация и нагрузка'),
      subtitle: const Text('Пробег деталей · замеры · разгоны и замедления'),
      children: [
        for (final front in [true, false])
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(front ? 'Передний тормоз' : 'Задний тормоз'),
            subtitle: Text(
              [
                BikeSetup.individualBrakeTypes[setup.brakeType(front)] ?? '',
                if (BikeSetup.isDisc(setup.brakeType(front)))
                  '${setup.rotorMm(front)} мм',
                if (BikeSetup.isDisc(setup.brakeType(front)))
                  BikeSetup.padMaterials[setup.padMaterial(front)] ?? '',
              ].join(' · '),
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: widget.busy ? null : widget.onConfigure,
              icon: const Icon(Icons.tune),
              label: const Text('Комплектация'),
            ),
            TextButton.icon(
              onPressed: widget.busy ? null : widget.onAddParts,
              icon: const Icon(Icons.add),
              label: const Text('Колодки и роторы в учёт'),
            ),
          ],
        ),
        for (final part in v.parts.where(
          (p) => p.template.category == 'Тормоза',
        ))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(part.name),
            subtitle: Text(
              '${part.lifetimeKm(v.totalDistance).toStringAsFixed(1)} км детали · '
              '${part.usedKm(v.totalDistance).toStringAsFixed(1)} км после проверки\n'
              '${part.serviceStatus(v.totalDistance, v.recordedHours)}',
            ),
          ),
        FutureBuilder<List<SavedRoute>>(
          future: _rides,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              );
            }
            if (snapshot.hasError) {
              return const Text('Не удалось прочитать историю на устройстве.');
            }
            final selected = widget.selected;
            final since = selected?.template.category == 'Тормоза'
                ? selected?.serviceDate
                : null;
            final seen = <String>{};
            final rows = (snapshot.data ?? [])
                .where(
                  (r) =>
                      r.vehicleId == v.id &&
                      r.workoutDetails.brakeLoad != null &&
                      (since == null ||
                          (r.createdAt != null &&
                              !r.createdAt!.isBefore(since))) &&
                      seen.add(r.remoteId ?? r.localId),
                )
                .toList();
            final loads = rows.map((r) => r.workoutDetails.brakeLoad!).toList();
            final energyLoads = loads.where((l) => l.systemMassKg != null);
            final total = BrakeLoad(
              slowdowns: loads.fold(0, (s, l) => s + l.slowdowns),
              accelerations: loads.fold(0, (s, l) => s + l.accelerations),
              kineticKj: energyLoads.fold(0, (s, l) => s + l.kineticKj),
              coveredSeconds: loads.fold(0, (s, l) => s + l.coveredSeconds),
              slowingSeconds: loads.fold(0, (s, l) => s + l.slowingSeconds),
              systemMassKg: energyLoads.firstOrNull?.systemMassKg,
              massAssumed: loads.any((l) => l.massAssumed),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'По загруженной истории: ${rows.length} заездов с учётом нагрузки.'
                  '${since == null ? '' : '\nПосле проверки «${selected!.name}» '
                            '${since.toLocal().toString().split(' ').first}.'}',
                ),
                BrakeLoadCard(load: total, title: 'Нагрузка велосипеда'),
                TextButton(
                  onPressed: () => setState(() => _rides = _load()),
                  child: const Text('Перечитать историю устройства'),
                ),
                const Text(
                  'История других устройств загружается на экране «История тренировок». '
                  'Старые заезды без записи нагрузки в расчёт не входят.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

Future<BrakeInspection?> editBrakeInspection(
  BuildContext context,
  BikePart part,
) async {
  final prior = part.brakeInspection;
  final controllers = [
    TextEditingController(text: prior?.measuredMm.toString() ?? ''),
    TextEditingController(text: prior?.minimumMm.toString() ?? ''),
    TextEditingController(text: prior?.newMm.toString() ?? ''),
  ];
  final rotor = part.template.id.endsWith('rotor');
  var basis = rotor ? 'rotor' : prior?.basis ?? 'friction';
  String? error;
  final nav = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<BrakeInspection>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialog) => AlertDialog(
        title: Text('Замер: ${part.name}'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!rotor)
                  DropdownButtonFormField<String>(
                    initialValue: basis,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Что измерено',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'friction',
                        child: Text('Только рабочий слой'),
                      ),
                      DropdownMenuItem(
                        value: 'with_plate',
                        child: Text('Вместе с пластиной'),
                      ),
                      DropdownMenuItem(
                        value: 'rim_pad',
                        child: Text('Ободная колодка'),
                      ),
                    ],
                    onChanged: (v) => setDialog(() {
                      basis = v!;
                      for (final c in controllers) {
                        c.clear();
                      }
                    }),
                  ),
                const Text(
                  'Три значения должны относиться к одному способу измерения. '
                  'Минимум берите из инструкции именно вашей детали или маркировки ротора.',
                ),
                for (var i = 0; i < 3; i++)
                  TextField(
                    controller: controllers[i],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: [
                        'Сейчас, мм',
                        'Минимум производителя, мм',
                        'Новая деталь, мм',
                      ][i],
                    ),
                  ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = controllers
                  .map(
                    (c) => double.tryParse(c.text.trim().replaceAll(',', '.')),
                  )
                  .toList();
              final result = BrakeInspection.fromJson({
                'at': DateTime.now().toUtc().toIso8601String(),
                'basis': basis,
                'measured_mm': parsed[0],
                'minimum_mm': parsed[1],
                'new_mm': parsed[2],
              });
              if (result == null) {
                setDialog(
                  () => error =
                      'Укажите положительные значения до 30 мм. '
                      'Новая деталь должна быть толще минимума и не тоньше текущего замера.',
                );
                return;
              }
              Navigator.pop(context, result);
            },
            child: const Text('Сохранить замер'),
          ),
        ],
      ),
    ),
  );
  final result = await nav.push(route);
  await route.completed;
  for (final c in controllers) {
    c.dispose();
  }
  return result;
}
