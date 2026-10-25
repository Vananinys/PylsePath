import 'package:flutter/material.dart';

import '../models/vehicle.dart';
import '../models/bike_equipment.dart';
import '../services/garage_service.dart';
import '../models/activity_type.dart';
import '../models/bike_setup.dart';
import '../widgets/bike_workshop_scene.dart';
import '../widgets/bike_workshop_editors.dart';
import '../widgets/brake_workshop.dart';

/// Wait for removal of the exiting route before releasing form controllers.
Future<T?> _showVehicleDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<T>(context: context, builder: builder);
  final result = await navigator.push(route);
  await route.completed;
  return result;
}

class VehicleDetailScreen extends StatefulWidget {
  const VehicleDetailScreen({
    super.key,
    required this.vehicle,
    this.readOnly = false,
    this.service,
  });
  final Vehicle vehicle;
  final bool readOnly;
  final GarageService? service;
  @override
  State<VehicleDetailScreen> createState() => _VehicleDetailScreenState();
}

class _VehicleDetailScreenState extends State<VehicleDetailScreen> {
  late final _service = widget.service ?? GarageService();
  late Vehicle _vehicle = widget.vehicle;
  bool _busy = false, _photo = false;
  final _partKey = GlobalKey();
  void _openPart() {
    final target = _partKey.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 250),
      );
    }
  }

  String? _selected;
  String? _error;
  @override
  void initState() {
    super.initState();
    if (!widget.readOnly) _reload();
  }

  Future<void> _reload() async {
    if (mounted) setState(() => _busy = true);
    try {
      var v = await _service.fetchVehicle(_vehicle.id);
      if (mounted) {
        setState(() {
          _vehicle = v;
          _error = null;
        });
      }
    } on GarageServiceException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(Vehicle next) async {
    if (_busy || !mounted) return;
    if (_service.sessionVehicle?.id == _vehicle.id) {
      setState(
        () => _error = 'Этот велосипед участвует в текущем заезде. Завершите тренировку перед изменением комплектации.',
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final saved = await _service.saveEquipment(next);
      if (mounted) {
        setState(() {
          _vehicle = saved;
          _error = null;
        });
      }
    } on GarageServiceException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _savePart(BikePart part) => _save(
    _vehicle.copyWith(
      parts: _vehicle.parts.map((p) => p.id == part.id ? part : p).toList(),
    ),
  );
  Future<void> _measureBrake(BikePart part) async {
    final measurement = await editBrakeInspection(context, part);
    if (measurement == null || !mounted) return;
    await _savePart(
      part.copyWith(
        history: [
          {
            ...measurement.toJson(),
            'km': _vehicle.totalDistance,
            'note':
                '${measurement.measuredMm} мм · предел ${measurement.minimumMm} мм · '
                'новая ${measurement.newMm} мм',
          },
          ...part.history,
        ],
      ),
    );
  }

  Future<void> _addBrakeParts() async {
    final setup = _vehicle.drivetrain?.setup ?? const BikeSetup();
    final ids = <String>[
      for (final front in [true, false]) ...[
        if (BikeSetup.isDisc(setup.brakeType(front)) ||
            setup.brakeType(front) == 'rim')
          '${front ? 'front' : 'rear'}_pads',
        if (BikeSetup.isDisc(setup.brakeType(front)))
          '${front ? 'front' : 'rear'}_rotor',
      ],
    ];
    final added = ids
        .where((id) => !_vehicle.parts.any((p) => p.template.id == id))
        .map((id) {
          final template = BikePartTemplate.find(id);
          return BikePart(
            id: 'part_${DateTime.now().microsecondsSinceEpoch}_$id',
            templateId: id,
            name: template.name,
            lastServiceKm: _vehicle.totalDistance,
            installedKm: _vehicle.totalDistance,
            lastServiceHours: _vehicle.recordedHours,
            installedHours: _vehicle.recordedHours,
            // This is the start of accounting, not a claim of a new part.
            condition:
                'Начало учёта. Уточните предыдущий пробег в паспорте детали.',
          );
        })
        .toList();
    if (added.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Для выбранных тормозов все доступные детали уже учтены.',
          ),
        ),
      );
      return;
    }
    if (_vehicle.parts.length + added.length > 50) {
      setState(
        () => _error = 'В гараже можно учитывать до 50 деталей велосипеда.',
      );
      return;
    }
    await _save(_vehicle.copyWith(parts: [..._vehicle.parts, ...added]));
  }

  Future<void> _editBike() async {
    final name = TextEditingController(text: _vehicle.name);
    final weight = TextEditingController(text: _vehicle.weightKg.toString());
    final wheel = TextEditingController(text: _vehicle.wheelSize.toString());
    var ebike = _vehicle.isEbike;
    var activity = _vehicle.activityType;
    String? error;
    final result = await _showVehicleDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Велосипед'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Название'),
                ),
                DropdownButtonFormField<ActivityType>(
                  initialValue: activity,
                  decoration: const InputDecoration(labelText: 'Тип'),
                  items: ActivityType.values
                      .map(
                        (a) => DropdownMenuItem(value: a, child: Text(a.label)),
                      )
                      .toList(),
                  onChanged: (a) {
                    if (a != null) activity = a;
                  },
                ),
                TextField(
                  controller: weight,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Вес, кг · 0 если неизвестно',
                  ),
                ),
                TextField(
                  controller: wheel,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Колёса, дюймы · 0 если неизвестно',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Электропривод'),
                  value: ebike,
                  onChanged: (v) => setDialog(() => ebike = v),
                ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final w = double.tryParse(weight.text.replaceAll(',', '.'));
                final s = double.tryParse(wheel.text.replaceAll(',', '.'));
                if (name.text.trim().isEmpty ||
                    w == null ||
                    s == null ||
                    !w.isFinite ||
                    !s.isFinite ||
                    w < 0 ||
                    w > 150 ||
                    s < 0 ||
                    s > 40) {
                  setDialog(
                    () => error =
                        'Проверьте название, вес 0–150 кг и колёса 0–40″',
                  );
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (result == true) {
      await _save(
        _vehicle.copyWith(
          name: name.text.trim(),
          transportType: activity.name,
          weightKg: double.parse(weight.text.replaceAll(',', '.')),
          wheelSize: double.parse(wheel.text.replaceAll(',', '.')),
          isEbike: ebike,
        ),
      );
    }
    name.dispose();
    weight.dispose();
    wheel.dispose();
  }

  Future<void> _editDrivetrain() async {
    final d = _vehicle.drivetrain ?? const BikeDrivetrain();
    final front = TextEditingController(text: d.front.join(', '));
    final rear = TextEditingController(text: d.rear.join(', '));
    final circumference = TextEditingController(
      text: d.circumference.toString(),
    );
    final cadence = TextEditingController(
      text: d.targetCadence.round().toString(),
    );
    String? error;
    BikeDrivetrain? result;
    await _showVehicleDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Передачи велосипеда'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Укажите число зубьев на звёздах. Спереди — от маленькой к большой, сзади — от большой к маленькой.',
                ),
                TextField(
                  controller: front,
                  decoration: const InputDecoration(
                    labelText: 'Передние звёзды',
                    hintText: '24, 34, 42',
                  ),
                ),
                TextField(
                  controller: rear,
                  decoration: const InputDecoration(
                    labelText: 'Задние звёзды',
                    hintText: '28, 24, 22, 20, 18, 16, 14',
                  ),
                ),
                TextField(
                  controller: circumference,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Окружность колеса, м',
                    helperText:
                        'Измерьте один полный оборот нагруженного колеса',
                  ),
                ),
                TextField(
                  controller: cadence,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Желаемый каденс, об/мин (40–120)',
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    ActionChip(
                      label: const Text('21 (3×7)'),
                      onPressed: () {
                        front.text = '24, 34, 42';
                        rear.text = '28, 24, 22, 20, 18, 16, 14';
                      },
                    ),
                    ActionChip(
                      label: const Text('24 (3×8)'),
                      onPressed: () {
                        front.text = '22, 32, 42';
                        rear.text = '32, 28, 24, 21, 18, 15, 13, 11';
                      },
                    ),
                    ActionChip(
                      label: const Text('12 (1×12)'),
                      onPressed: () {
                        front.text = '32';
                        rear.text =
                            '51, 45, 39, 33, 28, 24, 21, 18, 16, 14, 12, 10';
                      },
                    ),
                  ],
                ),
                const Text(
                  'Наборы — примеры. Сверьте зубья со своим велосипедом.',
                  style: TextStyle(fontSize: 12),
                ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                List<int>? parse(String s, int max) {
                  final tokens = s
                      .split(RegExp(r'[,; ]+'))
                      .where((e) => e.isNotEmpty)
                      .toList();
                  final values = tokens.map(int.tryParse).toList();
                  if (values.isEmpty ||
                      values.length > max ||
                      values.any((v) => v == null || v < 8 || v > 80)) {
                    return null;
                  }
                  return values.cast<int>().toSet().toList()..sort();
                }

                final f = parse(front.text, 3), r = parse(rear.text, 14);
                final c = double.tryParse(
                      circumference.text.replaceAll(',', '.'),
                    ),
                    rpm = double.tryParse(cadence.text.replaceAll(',', '.'));
                if (f == null ||
                    r == null ||
                    c == null ||
                    rpm == null ||
                    !c.isFinite ||
                    !rpm.isFinite ||
                    c < 1 ||
                    c > 3 ||
                    rpm < 40 ||
                    rpm > 120) {
                  setDialog(
                    () => error = 'Проверьте звёзды (8–80 зубьев), окружность 1–3 м и каденс 40–120',
                  );
                  return;
                }
                result = BikeDrivetrain(
                  setup: d.setup,
                  front: f,
                  rear: r.reversed.toList(),
                  circumference: c,
                  targetCadence: rpm,
                );
                Navigator.pop(ctx);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (result != null) await _save(_vehicle.copyWith(drivetrain: result));
    front.dispose();
    rear.dispose();
    circumference.dispose();
    cadence.dispose();
  }

  Future<void> _editPart(BikePart part) async {
    final hours = TextEditingController(
      text: part.intervalHours.toStringAsFixed(1),
    );
    final hoursBaseline = TextEditingController(
      text: (part.lastServiceHours ?? _vehicle.recordedHours).toStringAsFixed(
        3,
      ),
    );
    final days = TextEditingController(text: '${part.intervalDays}');
    var serviceAt = part.serviceDate?.toLocal();
    final name = TextEditingController(text: part.name);
    final interval = TextEditingController(
      text: part.intervalKm.toStringAsFixed(0),
    );
    final baseline = TextEditingController(
      text: part.lastServiceKm.toStringAsFixed(1),
    );
    final condition = TextEditingController(text: part.condition ?? '');
    String? error;
    final result = await _showVehicleDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(part.name),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  maxLength: 60,
                  decoration: const InputDecoration(
                    labelText: 'Название / модель детали',
                  ),
                ),
                TextField(
                  controller: interval,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Интервал проверки, км',
                    helperText:
                        '0 — без напоминания. Укажите по инструкции детали.',
                  ),
                ),
                TextField(
                  controller: baseline,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Пробег при последнем обслуживании',
                    helperText:
                        'Текущий: ${_vehicle.totalDistance.toStringAsFixed(1)} км',
                  ),
                ),
                TextField(
                  controller: days,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Интервал по времени, дней',
                    helperText: '0 — без срока по дате. Сработает первый из заданных интервалов.',
                  ),
                ),
                TextField(
                  controller: hours,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Интервал проверки, часов',
                    helperText:
                        '0 — без интервала. По инструкции производителя.',
                  ),
                ),
                TextField(
                  controller: hoursBaseline,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Часы велосипеда при последней проверке',
                    helperText:
                        'Сейчас: ${_vehicle.recordedHours.toStringAsFixed(1)} ч записанных тренировок без пауз',
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: Text(
                    serviceAt == null
                        ? 'Указать дату последней проверки'
                        : 'Последняя проверка: ${serviceAt.toString().split(' ').first}',
                  ),
                  onPressed: () async {
                    final now = DateTime.now();
                    final date = await showDatePicker(
                      context: ctx,
                      initialDate: serviceAt?.isAfter(now) == true
                          ? now
                          : serviceAt ?? now,
                      firstDate: DateTime(1970),
                      lastDate: now,
                    );
                    if (date != null && ctx.mounted) {
                      setDialog(() => serviceAt = date);
                    }
                  },
                ),
                TextField(
                  controller: condition,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Результат осмотра / измерение',
                    hintText: 'Например: растяжение цепи 0,5%',
                  ),
                ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final dayInterval = int.tryParse(days.text.trim());
                final h = double.tryParse(hours.text.replaceAll(',', '.'));
                final hb = double.tryParse(
                  hoursBaseline.text.replaceAll(',', '.'),
                );
                if (h == null ||
                    hb == null ||
                    !h.isFinite ||
                    !hb.isFinite ||
                    h < 0 ||
                    h > 100000 ||
                    hb < 0 ||
                    hb > _vehicle.recordedHours + .001) {
                  setDialog(
                    () => error =
                        'Проверьте интервал часов и отметку последней проверки',
                  );
                  return;
                }
                if (dayInterval != null &&
                    dayInterval > 0 &&
                    serviceAt == null) {
                  setDialog(
                    () => error = 'Укажите дату последней проверки для календарного интервала',
                  );
                  return;
                }
                final i = double.tryParse(interval.text.replaceAll(',', '.')),
                    b = double.tryParse(baseline.text.replaceAll(',', '.'));
                if (dayInterval == null ||
                    dayInterval < 0 ||
                    dayInterval > 3650 ||
                    name.text.trim().isEmpty ||
                    i == null ||
                    b == null ||
                    !i.isFinite ||
                    !b.isFinite ||
                    i < 0 ||
                    i > 100000 ||
                    b < 0 ||
                    b > _vehicle.totalDistance + .1) {
                  setDialog(
                    () => error =
                        'Проверьте интервал и пробег последнего обслуживания',
                  );
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (result == true) {
      await _savePart(
        part.copyWith(
          installedKm: part.installedKm ?? part.lastServiceKm,
          intervalHours: double.parse(hours.text.replaceAll(',', '.')),
          lastServiceHours:
              part.lastServiceHours == null &&
                  double.parse(hours.text.replaceAll(',', '.')) == 0
              ? null
              : double.parse(hoursBaseline.text.replaceAll(',', '.')),
          name: name.text.trim(),
          intervalKm: double.parse(interval.text.replaceAll(',', '.')),
          intervalDays: int.parse(days.text.trim()),
          lastServiceAt: serviceAt,
          lastServiceKm: double.parse(baseline.text.replaceAll(',', '.')),
          condition: condition.text.trim(),
        ),
      );
    }
    name.dispose();
    interval.dispose();
    baseline.dispose();
    condition.dispose();
    days.dispose();
    hours.dispose();
    hoursBaseline.dispose();
  }

  Future<void> _servicePart(BikePart part) async {
    final note = TextEditingController();
    final cost = TextEditingController();
    String? error;
    String action = 'Проверка';
    final result = await _showVehicleDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text('Обслуживание: ${part.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: action,
                  items: ['Проверка', 'Обслуживание', 'Замена']
                      .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                      .toList(),
                  onChanged: (v) => setDialog(() => action = v!),
                ),
                TextField(
                  controller: note,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Результат, модель новой детали, заметка',
                  ),
                ),
                Text(
                  'Пробег: ${_vehicle.totalDistance.toStringAsFixed(1)} км. Начнётся новый интервал проверки.',
                ),
                TextField(
                  controller: cost,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Расходы, ₽',
                    helperText: 'Необязательно, детали и работа вместе',
                  ),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final amount = cost.text.trim().isEmpty
                    ? 0.0
                    : double.tryParse(cost.text.trim().replaceAll(',', '.'));
                if (amount == null ||
                    !amount.isFinite ||
                    amount < 0 ||
                    amount > 1e8) {
                  setDialog(() => error = 'Укажите сумму от 0 до 100 млн ₽');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Записать'),
            ),
          ],
        ),
      ),
    );
    if (result == true) {
      await _savePart(
        part.copyWith(
          lastServiceKm: _vehicle.totalDistance,
          lastServiceHours: _vehicle.recordedHours,
          installedHours: action == 'Замена'
              ? _vehicle.recordedHours
              : part.installedHours ??
                    part.lastServiceHours ??
                    _vehicle.recordedHours,
          priorHours: action == 'Замена' ? 0 : part.priorHours,
          installedKm: action == 'Замена'
              ? _vehicle.totalDistance
              : part.installedKm ?? part.lastServiceKm,
          installedAt: action == 'Замена' ? DateTime.now() : part.installedAt,
          priorKm: action == 'Замена' ? 0 : part.priorKm,
          lastServiceAt: DateTime.now(),
          condition: note.text.trim(),
          history: [
            {
              'at': DateTime.now().toUtc().toIso8601String(),
              'km': _vehicle.totalDistance,
              'action': action,
              'note': note.text.trim(),
              'cost':
                  double.tryParse(cost.text.trim().replaceAll(',', '.')) ?? 0,
              'currency': 'RUB',
              'component_km': part.lifetimeKm(_vehicle.totalDistance),
              'hours': _vehicle.recordedHours,
              'component_hours': part.lifetimeHours(_vehicle.recordedHours),
              'part_name': part.name,
              'brand': part.brand,
              'model': part.model,
            },
            ...part.history,
          ].toList(),
        ),
      );
    }
    note.dispose();
    cost.dispose();
  }

  Future<void> _addPart() async {
    if (_vehicle.parts.length >= 50) {
      setState(() => _error = 'В велосипеде уже 50 деталей.');
      return;
    }
    final template = await chooseBikePart(context);
    if (template == null || !mounted) return;
    final part = BikePart(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: template.name,
      templateId: template.id,
      x: template.x,
      y: template.y,
      installedKm: _vehicle.totalDistance,
      installedAt: DateTime.now(),
      lastServiceKm: _vehicle.totalDistance,
      lastServiceHours: _vehicle.recordedHours,
      installedHours: _vehicle.recordedHours,
    );
    final configured = await editBikePartSpecifications(
      context,
      part,
      _vehicle.totalDistance,
    );
    if (configured != null && mounted) {
      await _save(_vehicle.copyWith(parts: [..._vehicle.parts, configured]));
      if (mounted) setState(() => _selected = configured.id);
    }
  }

  Future<void> _editSetup() async {
    final drive =
        _vehicle.drivetrain ?? const BikeDrivetrain(gearsConfigured: false);
    final setup = await editBikeSetup(
      context,
      drive.setup,
      ebike: _vehicle.isEbike,
      drivetrain: drive,
      parts: _vehicle.parts,
      diagram: _vehicle.activityType == ActivityType.roadCycling
          ? 'road'
          : _vehicle.activityType == ActivityType.gravelRiding
          ? 'gravel'
          : 'hardtail',
    );
    if (setup != null && mounted) {
      await _save(_vehicle.copyWith(drivetrain: drive.withSetup(setup)));
    }
  }

  Future<void> _editSpecifications(BikePart part) async {
    final result = await editBikePartSpecifications(
      context,
      part,
      _vehicle.totalDistance,
    );
    if (result != null && mounted) await _savePart(result);
  }

  Future<void> _addPriorMileage() async {
    if (_service.sessionVehicle?.id == _vehicle.id) {
      setState(
        () => _error = 'Завершите текущий заезд перед изменением одометра.',
      );
      return;
    }
    final input = TextEditingController();
    String? error;
    final km = await _showVehicleDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Пробег до PulsePath'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Добавьте прежний пробег велосипеда. Записанные интервалы обслуживания сохранятся.',
              ),
              TextField(
                controller: input,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Добавить, км',
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final n = double.tryParse(input.text.replaceAll(',', '.'));
                if (n == null || !n.isFinite || n <= 0 || n > 1000000) {
                  setDialog(() => error = 'Введите от 0,1 до 1000000 км');
                  return;
                }
                Navigator.pop(ctx, n);
              },
              child: const Text('Добавить'),
            ),
          ],
        ),
      ),
    );
    input.dispose();
    if (km == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final v = await _service.addPriorMileage(_vehicle, km);
      if (mounted) setState(() => _vehicle = v);
    } on GarageServiceException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removePart(BikePart part) async {
    final confirmed = await _showVehicleDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Удалить ${part.name}?'),
        content: const Text('Метка и журнал этой детали будут удалены.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _save(
        _vehicle.copyWith(
          parts: _vehicle.parts.where((p) => p.id != part.id).toList(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _vehicle;
    final parts = v.parts;
    final selected =
        parts.where((p) => p.id == _selected).firstOrNull ?? parts.firstOrNull;
    final hasPhoto = v.photoUrl?.startsWith('http') ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Text(v.name),
        actions: [
          if (!widget.readOnly)
            IconButton(
              tooltip: 'Редактировать велосипед',
              onPressed: _busy ? null : _editBike,
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              MaterialBanner(
                content: Text(_error!),
                actions: [
                  TextButton(
                    onPressed: _reload,
                    child: const Text('Повторить'),
                  ),
                ],
              ),
            BikeWorkshopScene(
              parts: parts,
              odometer: v.totalDistance,
              setup: v.drivetrain?.setup ?? const BikeSetup(),
              selectedId: selected?.id,
              diagram: v.activityType == ActivityType.roadCycling
                  ? 'road'
                  : v.activityType == ActivityType.gravelRiding
                  ? 'gravel'
                  : 'hardtail',
              totalHours: v.recordedHours,
              drivetrain: v.drivetrain,
              isEbike: v.isEbike,
              onAppearance: widget.readOnly || _busy ? null : _editSetup,
              readOnly: widget.readOnly,
              onOpen: _openPart,
              onSelect: (id) => setState(() => _selected = id),
            ),
            if (hasPhoto)
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    SwitchListTile(
                      dense: true,
                      title: const Text('Фото велосипеда'),
                      value: _photo,
                      onChanged: (v) => setState(() => _photo = v),
                    ),
                    if (_photo)
                      Image.network(
                        v.photoUrl!,
                        height: 220,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Не удалось загрузить фото'),
                        ),
                      ),
                  ],
                ),
              ),
            Text(
              '${v.totalDistance.toStringAsFixed(1)} км · ${widget.readOnly ? '' : '${v.recordedHours.toStringAsFixed(1)} ч · '}${v.activityType.label}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              '${v.weightKg > 0 ? '${v.weightKg} кг · ' : ''}${v.wheelSize > 0 ? 'Колёса ${v.wheelSize}″' : ''}${v.isEbike ? ' · Электропривод' : ''}',
            ),
            if (widget.readOnly && v.drivetrain?.gearsConfigured == true)
              Text('${v.drivetrain!.speeds} передач'),
            if (!widget.readOnly) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.tune),
                title: const Text('Посадка, покрышки, багаж и оформление'),
                subtitle: Text(
                  '${BikeSetup.postures[(v.drivetrain?.setup ?? const BikeSetup()).posture]} · Багаж ${(v.drivetrain?.setup.cargoKg ?? 0).toStringAsFixed(1)} кг',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : _editSetup,
              ),
              BrakeWorkshop(
                vehicle: v,
                busy: _busy,
                selected: selected,
                onConfigure: _editSetup,
                onAddParts: _addBrakeParts,
              ),
              const Text(
                'Пробег заезда автоматически добавляется выбранному велосипеду после синхронизации. Выберите его перед стартом тренировки. Настройки расчётов фиксируются на старте.',
              ),
              TextButton.icon(
                onPressed: _busy ? null : _addPriorMileage,
                icon: const Icon(Icons.add_road),
                label: const Text('Добавить пробег до PulsePath'),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Показывать в публичном профиле'),
                subtitle: const Text(
                  'Фото, название, характеристики и пробег. Журнал обслуживания доступен только вам.',
                ),
                value: v.isPublic,
                onChanged: _busy ? null : (b) => _save(v.copyWith(isPublic: b)),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.settings),
                title: const Text('Передачи и окружность колеса'),
                subtitle: Text(
                  v.drivetrain?.gearsConfigured != true
                      ? 'Настройте для экспериментальной подсказки'
                      : '${v.drivetrain!.speeds} передач · ${v.drivetrain!.front.join('/')} × ${v.drivetrain!.rear.join('/')}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : _editDrivetrain,
              ),
              const Divider(),
              Text(
                'Состояние и обслуживание',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                'Расходы по сохранённым записям: ${v.parts.fold(0.0, (sum, part) => sum + part.serviceCostRubles).toStringAsFixed(0)} ₽',
              ),
              if (v.parts.any(
                (part) =>
                    part.due(v.totalDistance, totalHours: v.recordedHours),
              ))
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Пора проверить: ${v.parts.where((part) => part.due(v.totalDistance, totalHours: v.recordedHours)).map((part) => part.name).join(', ')}',
                    ),
                  ),
                ),
              const Text(
                'Полоса показывает использованную часть заданного интервала проверки, а не измеренный физический износ. Интервалы задавайте по инструкции к деталям и условиям езды.',
              ),
              const SizedBox(height: 8),
              if (parts.isEmpty) ...[
                const Text(
                  'Начните учёт с текущего пробега. Историю до этого момента можно указать в настройках каждой детали.',
                ),
                FilledButton.tonal(
                  onPressed: _busy
                      ? null
                      : () => _save(
                          v.copyWith(
                            parts: BikePart.initial(v.totalDistance)
                                .where(
                                  (p) =>
                                      [
                                        'chain',
                                        'front_tyre',
                                        'rear_tyre',
                                        'brakes',
                                      ].contains(p.id) ||
                                      (p.id == 'fork' &&
                                          v.activityType ==
                                              ActivityType.mountainBiking),
                                )
                                .map(
                                  (p) => p.copyWith(
                                    lastServiceHours: v.recordedHours,
                                    installedHours: v.recordedHours,
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                  child: const Text('Добавить основные детали'),
                ),
              ],
              const Text(
                'Выберите деталь на схеме или в списке над ней. Открыта одна карточка обслуживания.',
              ),
              if (selected != null) ...[
                Card(
                  key: _partKey,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                selected.name,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Удалить деталь',
                              onPressed: _busy
                                  ? null
                                  : () => _removePart(selected),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                        Text(
                          'После обслуживания: ${selected.usedKm(v.totalDistance).toStringAsFixed(1)} км',
                        ),
                        Text(
                          'Пробег детали: ${selected.lifetimeKm(v.totalDistance).toStringAsFixed(1)} км${selected.installedKm == null ? ' · учёт с последней известной отметки' : ''}',
                        ),
                        Text(
                          selected.lifetimeHours(v.recordedHours) == null
                              ? 'Часы детали: отметка установки не задана'
                              : 'Часы детали: ${selected.lifetimeHours(v.recordedHours)!.toStringAsFixed(1)} ч',
                        ),
                        Text(
                          selected.serviceStatus(
                            v.totalDistance,
                            v.recordedHours,
                          ),
                        ),
                        if (selected.brand.isNotEmpty ||
                            selected.model.isNotEmpty)
                          Text('${selected.brand} ${selected.model}'.trim()),
                        if (selected.massGrams > 0)
                          Text(
                            'Масса: ${selected.massGrams.toStringAsFixed(0)} г',
                          ),
                        if (selected.intervalKm > 0) ...[
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: selected.usedFraction(v.totalDistance),
                            color:
                                selected.due(
                                  v.totalDistance,
                                  totalHours: v.recordedHours,
                                )
                                ? Colors.red
                                : Colors.teal,
                          ),
                          Text(
                            selected.due(
                                  v.totalDistance,
                                  totalHours: v.recordedHours,
                                )
                                ? 'Подошёл срок проверки'
                                : 'До проверки: ${(selected.intervalKm - selected.usedKm(v.totalDistance)).toStringAsFixed(0)} км',
                          ),
                        ] else
                          const Text('Интервал проверки не задан'),
                        if (selected.condition?.isNotEmpty ?? false)
                          Text('Последний осмотр: ${selected.condition}'),
                        if (selected.brakeInspection
                            case final measurement?) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Замер ${measurement.at.toLocal().toString().split(' ').first}: '
                            '${measurement.measuredMm} мм · минимум ${measurement.minimumMm} мм',
                          ),
                          LinearProgressIndicator(
                            value: measurement.consumedFraction,
                            color: measurement.limitReached
                                ? Colors.red
                                : Colors.teal,
                          ),
                          Text(
                            measurement.limitReached
                                ? 'Достигнут указанный предел. Деталь требует замены.'
                                : 'Израсходовано ${(measurement.consumedFraction * 100).round()}% '
                                      'допустимой толщины по замеру',
                          ),
                        ],
                        if (selected.nextServiceDate != null)
                          Text(
                            'Проверка по дате: ${selected.nextServiceDate!.toString().split(' ').first} · ${selected.daysRemaining()! <= 0 ? 'срок подошёл' : 'через ${selected.daysRemaining()} дн.'}',
                          ),
                        if (selected.intervalDays > 0 &&
                            selected.nextServiceDate == null)
                          const Text(
                            'Укажите дату последней проверки, чтобы считать срок',
                          ),
                        Wrap(
                          spacing: 8,
                          children: [
                            if (selected.acceptsBrakeMeasurement)
                              TextButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _measureBrake(selected),
                                icon: const Icon(Icons.straighten),
                                label: const Text('Замер износа'),
                              ),
                            TextButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editSpecifications(selected),
                              icon: const Icon(Icons.badge_outlined),
                              label: const Text('Паспорт детали'),
                            ),
                            TextButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editPart(selected),
                              icon: const Icon(Icons.tune),
                              label: const Text('Настроить'),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: _busy
                                  ? null
                                  : () => _servicePart(selected),
                              icon: const Icon(Icons.build_outlined),
                              label: const Text('Обслужено'),
                            ),
                          ],
                        ),
                        if (selected.history.isNotEmpty)
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: Text(
                              'Журнал · ${selected.history.length} записей',
                            ),
                            children: [
                              for (final e in selected.history)
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    '${e['action']} · ${(e['km'] as num?)?.toStringAsFixed(1) ?? '—'} км',
                                  ),
                                  subtitle: Text(
                                    '${(e['at'] ?? '').toString().split('T').first}\n${e['note'] ?? ''}${e['hours'] is num ? '\nЧасы велосипеда: ${(e['hours'] as num).toStringAsFixed(1)} ч' : ''}${e['component_km'] is num ? '\nПробег детали: ${(e['component_km'] as num).toStringAsFixed(1)} км' : ''}${e['currency'] == 'RUB' && e['cost'] is num ? '\n${(e['cost'] as num).toStringAsFixed(0)} ₽' : ''}',
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              TextButton.icon(
                onPressed: _busy ? null : _addPart,
                icon: const Icon(Icons.add),
                label: const Text('Добавить деталь'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
