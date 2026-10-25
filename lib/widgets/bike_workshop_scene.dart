import 'package:flutter/material.dart';

import '../models/bike_equipment.dart';
import '../models/bike_setup.dart';
import 'bike_diagram.dart';

/// A single, fitted diagram. Tap targets follow the rendered component paths.
class BikeWorkshopScene extends StatefulWidget {
  const BikeWorkshopScene({
    super.key,
    required this.parts,
    required this.odometer,
    required this.setup,
    this.selectedId,
    required this.onSelect,
    this.road = false,
    this.diagram = 'hardtail',
    this.totalHours = 0,
    this.readOnly = false,
    this.onOpen,
    this.drivetrain,
    this.isEbike = false,
    this.onAppearance,
  });
  final List<BikePart> parts;
  final double odometer, totalHours;
  final BikeSetup setup;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final bool road, readOnly;
  final String diagram;
  final VoidCallback? onOpen;
  final BikeDrivetrain? drivetrain;
  final bool isEbike;
  final VoidCallback? onAppearance;
  @override
  State<BikeWorkshopScene> createState() => _BikeWorkshopSceneState();
}

class _BikeWorkshopSceneState extends State<BikeWorkshopScene> {
  final _transform = TransformationController();
  String? _category;
  Size _board = Size.zero;
  String get _kind => widget.setup.diagram == 'auto'
      ? (widget.road ? 'road' : widget.diagram)
      : widget.setup.diagram;
  @override
  void didUpdateWidget(covariant BikeWorkshopScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.setup.diagram != widget.setup.diagram ||
        oldWidget.diagram != widget.diagram) {
      _transform.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.parts
        .where((p) => _category == null || p.template.category == _category)
        .toList();
    final selected = widget.parts
        .where((p) => p.id == widget.selectedId)
        .firstOrNull;
    final geometry = BikeDiagramGeometry(
      _kind,
      setup: widget.setup,
      drivetrain: widget.drivetrain,
      parts: widget.parts,
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    BikeSetup.diagrams[_kind] ?? 'Велосипед',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Уменьшить',
                  onPressed: () => _zoom(.8),
                  icon: const Icon(Icons.remove),
                ),
                IconButton(
                  tooltip: 'Увеличить',
                  onPressed: () => _zoom(1.25),
                  icon: const Icon(Icons.add),
                ),
                IconButton(
                  tooltip: 'Сбросить масштаб',
                  onPressed: () => _transform.value = Matrix4.identity(),
                  icon: const Icon(Icons.fit_screen),
                ),
              ],
            ),
          ),
          if (!widget.readOnly && widget.parts.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('Все узлы'),
                    selected: _category == null,
                    onSelected: (_) => setState(() => _category = null),
                  ),
                  for (final c in BikePartTemplate.categories)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ChoiceChip(
                        label: Text(c),
                        selected: _category == c,
                        onSelected: (_) => setState(() => _category = c),
                      ),
                    ),
                ],
              ),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              _board = Size(constraints.maxWidth, constraints.maxWidth * .68);
              return SizedBox(
                height: _board.height,
                child: InteractiveViewer(
                  transformationController: _transform,
                  minScale: 1,
                  maxScale: 3,
                  child: GestureDetector(
                    key: const ValueKey('bike-diagram-target'),
                    behavior: HitTestBehavior.opaque,
                    onTapUp: widget.readOnly
                        ? null
                        : (d) => _pick(geometry, d.localPosition, visible),
                    child: SizedBox(
                      width: _board.width,
                      height: _board.height,
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: BikeDiagramPainter(
                            geometry: geometry,
                            color: Color(widget.setup.frameColor),
                            parts: widget.readOnly ? const [] : widget.parts,
                            selectedId: widget.selectedId,
                            odometer: widget.odometer,
                            totalHours: widget.totalHours,
                            isEbike: widget.isEbike,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          if (!widget.readOnly)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.onAppearance != null)
                    TextButton.icon(
                      onPressed: widget.onAppearance,
                      icon: const Icon(Icons.palette_outlined),
                      label: const Text('Настроить рисунок велосипеда'),
                    ),
                  Text(
                    widget.parts.isEmpty
                        ? 'Добавьте детали для учёта обслуживания.'
                        : 'Нажмите на деталь. Красный контур — пора проверить. Масштабируйте двумя пальцами.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (visible.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        'parts-${_category ?? 'all'}-${widget.selectedId}-${visible.map((p) => p.id).join(',')}',
                      ),
                      initialValue: visible.any((p) => p.id == selected?.id)
                          ? selected!.id
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Выбрать деталь из списка',
                        isDense: true,
                      ),
                      items: visible
                          .map(
                            (p) => DropdownMenuItem(
                              value: p.id,
                              child: Text(
                                p.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (id) {
                        if (id != null) widget.onSelect(id);
                      },
                    ),
                  ],
                  if (selected != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      selected.serviceStatus(
                        widget.odometer,
                        widget.totalHours,
                      ),
                      style: TextStyle(
                        color:
                            selected.due(
                              widget.odometer,
                              totalHours: widget.totalHours,
                            )
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: geometry.visible(selected.template.id)
                          ? () => _focus(geometry, selected)
                          : null,
                      icon: const Icon(Icons.zoom_in),
                      label: const Text('Рассмотреть деталь'),
                    ),
                    if (!geometry.visible(selected.template.id))
                      const Text(
                        'Эта деталь не показана в выбранной комплектации. '
                        'Её паспорт и журнал доступны ниже.',
                      ),
                    if (widget.onOpen != null)
                      TextButton.icon(
                        onPressed: widget.onOpen,
                        icon: const Icon(Icons.build_outlined),
                        label: Text('Открыть: ${selected.name}'),
                      ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _zoom(double factor) {
    final old = _transform.value;
    final current = old.getMaxScaleOnAxis();
    final scale = (current * factor).clamp(1.0, 3.0);
    if (scale == 1) {
      _transform.value = Matrix4.identity();
      return;
    }
    final ratio = scale / current;
    final center = Offset(_board.width / 2, _board.height / 2);
    _transform.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(
        center.dx + (old.storage[12] - center.dx) * ratio,
        center.dy + (old.storage[13] - center.dy) * ratio,
        0,
      );
  }

  void _focus(BikeDiagramGeometry geometry, BikePart part) {
    final center = geometry.path(part.template.id).getBounds().center;
    final scale =
        (part.template.id.contains('wheel') ||
            part.template.id.contains('tyre') ||
            part.template.id == 'frame')
        ? 1.6
        : 3.0;
    final x = center.dx / 1000 * _board.width,
        y = center.dy / 680 * _board.height;
    _transform.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(
        _board.width / 2 - x * scale,
        _board.height / 2 - y * scale,
        0,
      );
  }

  Future<void> _pick(
    BikeDiagramGeometry geometry,
    Offset local,
    List<BikePart> parts,
  ) async {
    if (_board.width <= 0) return;
    final point = Offset(
      local.dx / _board.width * 1000,
      local.dy / _board.height * 680,
    );
    final hits = geometry.hit(
      point,
      parts,
      22 / _board.width * 1000 / _transform.value.getMaxScaleOnAxis(),
    );
    if (hits.isEmpty) return;
    if (hits.length == 1) {
      widget.onSelect(hits.single.id);
      return;
    }
    final id = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('Какую деталь открыть?')),
              for (final p in hits)
                ListTile(
                  title: Text(p.name),
                  subtitle: Text(
                    p.serviceStatus(widget.odometer, widget.totalHours),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, p.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (id != null && mounted) widget.onSelect(id);
  }
}
