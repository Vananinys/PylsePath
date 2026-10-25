import 'package:flutter/material.dart';

import '../models/bike_equipment.dart';
import '../models/bike_setup.dart';
import 'bike_diagram.dart';

Future<BikePartTemplate?> chooseBikePart(BuildContext context) =>
    showModalBottomSheet<BikePartTemplate>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .78,
          child: Column(
            children: [
              const ListTile(
                title: Text('Каталог деталей'),
                subtitle: Text(
                  'Добавляйте отдельные колёса, тормоза и несколько деталей одного типа. До 50 позиций.',
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final category in BikePartTemplate.categories)
                      ExpansionTile(
                        title: Text(category),
                        initiallyExpanded:
                            category == BikePartTemplate.categories.first,
                        children: [
                          for (final t in BikePartTemplate.all.where(
                            (t) => t.category == category,
                          ))
                            ListTile(
                              title: Text(t.name),
                              trailing: const Icon(Icons.add_circle_outline),
                              onTap: () => Navigator.pop(context, t),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

Future<BikePart?> editBikePartSpecifications(
  BuildContext context,
  BikePart part,
  double odometer,
) async {
  final route = DialogRoute<BikePart>(
    context: context,
    builder: (_) => _PartSpecifications(part: part, odometer: odometer),
  );
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  return result;
}

class _PartSpecifications extends StatefulWidget {
  const _PartSpecifications({required this.part, required this.odometer});
  final BikePart part;
  final double odometer;
  @override
  State<_PartSpecifications> createState() => _PartSpecificationsState();
}

class _PartSpecificationsState extends State<_PartSpecifications> {
  late final _name = TextEditingController(text: widget.part.name);
  late final _brand = TextEditingController(text: widget.part.brand);
  late final _model = TextEditingController(text: widget.part.model);
  late final _mass = TextEditingController(text: '${widget.part.massGrams}');
  late final _installed = TextEditingController(
    text: (widget.part.installedKm ?? widget.part.lastServiceKm)
        .toStringAsFixed(1),
  );
  late final _prior = TextEditingController(text: '${widget.part.priorKm}');
  late String _template = widget.part.template.id;
  String? _error;
  @override
  void dispose() {
    for (final c in [_name, _brand, _model, _mass, _installed, _prior]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Паспорт детали'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _template,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Узел на схеме'),
              items: BikePartTemplate.all
                  .map(
                    (t) => DropdownMenuItem(value: t.id, child: Text(t.name)),
                  )
                  .toList(),
              onChanged: (v) => _template = v!,
            ),
            _field(_name, 'Название', max: 60),
            _field(_brand, 'Производитель', max: 60),
            _field(_model, 'Модель / размер', max: 100),
            _field(_mass, 'Масса детали, г · 0 если неизвестно', number: true),
            _field(
              _installed,
              'Одометр велосипеда при установке, км',
              number: true,
            ),
            _field(_prior, 'Пробег детали до установки, км', number: true),
            Text(
              'Одометр сейчас: ${widget.odometer.toStringAsFixed(1)} км. Пробег детали продолжит считаться после обслуживания. При замене начнётся учёт новой детали.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Масса деталей справочная. Общий вес велосипеда указывается отдельно, чтобы не посчитать детали дважды.',
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
      FilledButton(onPressed: _submit, child: const Text('Сохранить')),
    ],
  );
  Widget _field(
    TextEditingController c,
    String label, {
    bool number = false,
    int? max,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      controller: c,
      maxLength: max,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(labelText: label),
    ),
  );
  void _submit() {
    double? read(TextEditingController c) =>
        double.tryParse(c.text.trim().replaceAll(',', '.'));
    final mass = read(_mass),
        installed = read(_installed),
        prior = read(_prior);
    if (_name.text.trim().isEmpty ||
        mass == null ||
        installed == null ||
        prior == null ||
        !mass.isFinite ||
        !installed.isFinite ||
        !prior.isFinite ||
        mass < 0 ||
        mass > 100000 ||
        installed < 0 ||
        installed > widget.odometer + .1 ||
        prior < 0 ||
        prior > 1000000) {
      setState(
        () => _error = 'Проверьте название, массу и пробег. Пробег установки не может превышать одометр.',
      );
      return;
    }
    Navigator.pop(
      context,
      widget.part.copyWith(
        name: _name.text.trim(),
        brand: _brand.text.trim(),
        model: _model.text.trim(),
        templateId: _template,
        massGrams: mass,
        installedKm: installed,
        priorKm: prior,
      ),
    );
  }
}

Future<BikeSetup?> editBikeSetup(
  BuildContext context,
  BikeSetup initial, {
  required bool ebike,
  BikeDrivetrain? drivetrain,
  List<BikePart> parts = const [],
  String diagram = 'hardtail',
}) async {
  final route = DialogRoute<BikeSetup>(
    context: context,
    builder: (_) => _SetupEditor(
      initial: initial,
      ebike: ebike,
      drivetrain: drivetrain,
      parts: parts,
      diagram: diagram,
    ),
  );
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  return result;
}

class _SetupEditor extends StatefulWidget {
  const _SetupEditor({
    required this.initial,
    required this.ebike,
    this.drivetrain,
    required this.parts,
    required this.diagram,
  });
  final BikeSetup initial;
  final bool ebike;
  final BikeDrivetrain? drivetrain;
  final List<BikePart> parts;
  final String diagram;
  @override
  State<_SetupEditor> createState() => _SetupEditorState();
}

class _SetupEditorState extends State<_SetupEditor> {
  late final _cargo = TextEditingController(text: '${widget.initial.cargoKg}');
  late String _posture = widget.initial.posture,
      _tyres = widget.initial.tyres,
      _assist = widget.initial.assistance;
  late int _color = widget.initial.frameColor;
  late String _diagram = widget.initial.diagram;
  late bool _reminders = widget.initial.maintenanceReminders;
  late final String _brakes = widget.initial.brakes;
  late String _transmission = widget.initial.transmission,
      _fork = widget.initial.fork;
  late String _frontBrake = widget.initial.brakeType(true),
      _rearBrake = widget.initial.brakeType(false),
      _frontPad = widget.initial.frontPadMaterial,
      _rearPad = widget.initial.rearPadMaterial;
  late int _frontRotor = widget.initial.frontRotorMm,
      _rearRotor = widget.initial.rearRotorMm;
  late bool _deepRims = widget.initial.deepRims,
      _showLabels = widget.initial.showLabels;
  late final _accessories = widget.initial.accessories.toSet();
  String? _error;
  @override
  void dispose() {
    _cargo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Вид велосипеда и параметры'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _cargo,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Багаж и дополнительный груз, кг',
                helperText: 'Без массы человека и велосипеда · 0–60 кг',
              ),
            ),
            _dropdown(
              'Модель на схеме',
              _diagram,
              BikeSetup.diagrams,
              (v) => _diagram = v,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: AspectRatio(
                aspectRatio: 1000 / 680,
                child: CustomPaint(
                  painter: BikeDiagramPainter(
                    geometry: BikeDiagramGeometry(
                      _diagram == 'auto' ? widget.diagram : _diagram,
                      drivetrain: widget.drivetrain,
                      parts: widget.parts,
                      setup: BikeSetup(
                        transmission: _transmission,
                        brakes: _brakes,
                        frontBrake: _frontBrake,
                        rearBrake: _rearBrake,
                        frontRotorMm: _frontRotor,
                        rearRotorMm: _rearRotor,
                        tyres: _tyres,
                        fork: _fork,
                        deepRims: _deepRims,
                        showLabels: _showLabels,
                        accessories: _accessories.toList(),
                      ),
                    ),
                    color: Color(_color),
                    parts: const [],
                    odometer: 0,
                    isEbike: widget.ebike,
                  ),
                ),
              ),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Трансмиссия, тормоза и оснащение'),
              initiallyExpanded: true,
              children: [
                _dropdown(
                  'Трансмиссия на рисунке',
                  _transmission,
                  BikeSetup.transmissions,
                  (v) => _transmission = v,
                ),
                const Text(
                  'В режиме «По настройкам передач» количество звёзд берётся из настроенной трансмиссии. Внешний вид не изменяет реальные передачи.',
                ),
                _brakeEditor(true),
                _brakeEditor(false),
                const Text(
                  'Размеры — описание установленной комплектации. '
                  'Совместимость ротора, крепления и колодок проверьте по инструкции производителя.',
                  style: TextStyle(fontSize: 12),
                ),
                _dropdown(
                  'Вилка',
                  _fork,
                  BikeSetup.forkTypes,
                  (v) => _fork = v,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Высокий профиль ободов'),
                  value: _deepRims,
                  onChanged: (v) => setState(() => _deepRims = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Подписи основных узлов'),
                  value: _showLabels,
                  onChanged: (v) => setState(() => _showLabels = v),
                ),
                for (final entry in BikeSetup.accessoryTypes.entries)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.value),
                    value: _accessories.contains(entry.key),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _accessories.add(entry.key);
                      } else {
                        _accessories.remove(entry.key);
                      }
                    }),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Напоминать об обслуживании'),
              subtitle: const Text(
                'Проверка при открытии приложения и после синхронизации заезда',
              ),
              value: _reminders,
              onChanged: (v) => setState(() => _reminders = v),
            ),
            _dropdown(
              'Посадка',
              _posture,
              BikeSetup.postures,
              (v) => _posture = v,
            ),
            _dropdown(
              'Покрышки',
              _tyres,
              BikeSetup.tyreTypes,
              (v) => _tyres = v,
            ),
            if (widget.ebike)
              _dropdown(
                'Помощь мотора',
                _assist,
                BikeSetup.assistModes,
                (v) => _assist = v,
              ),
            const SizedBox(height: 12),
            const Text('Цвет рамы'),
            Wrap(
              spacing: 8,
              children: [
                for (final c in BikeSetup.colors)
                  IconButton(
                    tooltip: 'Цвет ${BikeSetup.colors.indexOf(c) + 1}',
                    style: IconButton.styleFrom(backgroundColor: Color(c)),
                    onPressed: () => setState(() => _color = c),
                    icon: Icon(
                      _color == c ? Icons.check : Icons.circle_outlined,
                      color: Colors.white,
                    ),
                  ),
              ],
            ),
            const Text(
              'Посадка, покрышки, вес велосипеда и багаж учитываются в расчётной мощности. Калории зависят от массы человека, темпа и выбранной помощи мотора. Физический износ деталей не измеряется.',
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
          final kg = double.tryParse(_cargo.text.trim().replaceAll(',', '.'));
          if (kg == null || !kg.isFinite || kg < 0 || kg > 60) {
            setState(() => _error = 'Укажите багаж от 0 до 60 кг');
            return;
          }
          Navigator.pop(
            context,
            BikeSetup(
              transmission: _transmission,
              brakes: _brakes,
              frontBrake: _frontBrake,
              rearBrake: _rearBrake,
              frontRotorMm: _frontRotor,
              rearRotorMm: _rearRotor,
              frontPadMaterial: _frontPad,
              rearPadMaterial: _rearPad,
              fork: _fork,
              deepRims: _deepRims,
              showLabels: _showLabels,
              accessories: _accessories.toList(),
              diagram: _diagram,
              maintenanceReminders: _reminders,
              cargoKg: kg,
              posture: _posture,
              tyres: _tyres,
              assistance: _assist,
              frameColor: _color,
            ),
          );
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
  Widget _brakeEditor(bool front) {
    final type = front ? _frontBrake : _rearBrake;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(front ? 'Передний тормоз' : 'Задний тормоз'),
      subtitle: Text(BikeSetup.individualBrakeTypes[type] ?? type),
      children: [
        _dropdown(
          'Тип тормоза',
          type,
          {
            for (final e in BikeSetup.individualBrakeTypes.entries)
              if (!front || e.key != 'coaster') e.key: e.value,
          },
          (v) {
            if (front) {
              _frontBrake = v;
            } else {
              _rearBrake = v;
            }
          },
        ),
        if (BikeSetup.isDisc(type)) ...[
          DropdownButtonFormField<int>(
            initialValue: front ? _frontRotor : _rearRotor,
            decoration: const InputDecoration(labelText: 'Диаметр ротора'),
            items: BikeSetup.rotorSizes
                .map((mm) => DropdownMenuItem(value: mm, child: Text('$mm мм')))
                .toList(),
            onChanged: (v) => setState(() {
              if (front) {
                _frontRotor = v!;
              } else {
                _rearRotor = v!;
              }
            }),
          ),
          _dropdown(
            'Материал колодок',
            front ? _frontPad : _rearPad,
            BikeSetup.padMaterials,
            (v) {
              if (front) {
                _frontPad = v;
              } else {
                _rearPad = v;
              }
            },
          ),
        ],
      ],
    );
  }

  Widget _dropdown(
    String label,
    String value,
    Map<String, String> values,
    ValueChanged<String> onChanged,
  ) => DropdownButtonFormField<String>(
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: values.entries
        .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
        .toList(),
    onChanged: (v) => setState(() => onChanged(v!)),
  );
}
