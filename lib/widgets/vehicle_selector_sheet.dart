import 'package:flutter/material.dart';

import '../models/transport_type.dart';
import '../models/vehicle.dart';

/// Иконка техники по значению `garage.type` (лейбл [TransportType]).
IconData vehicleIconFor(String transportType) {
  switch (TransportType.fromDb(transportType)) {
    case TransportType.bicycle:
      return Icons.pedal_bike;
    case TransportType.scooter:
      return Icons.electric_scooter;
    case TransportType.running:
      return Icons.directions_run;
    case TransportType.walking:
      return Icons.directions_walk;
    case TransportType.other:
      return Icons.directions_bike;
  }
}

/// Человекочитаемый тип техники для карточек.
String vehicleTypeLabel(Vehicle vehicle) {
  final type = TransportType.fromDb(vehicle.transportType);
  if (type != TransportType.other) return type.label;
  // Неизвестное значение показываем как есть, если оно есть.
  return vehicle.transportType.trim().isEmpty
      ? 'Другое'
      : vehicle.transportType;
}

/// Шторка выбора техники для заезда (Vehicle Selector).
///
/// Карточки техники из таблицы `garage`: иконка типа, название, тип,
/// текущий пробег. Выбранная техника подсвечена акцентным цветом с галочкой.
/// Внизу — быстрый переход в Гараж для добавления новой техники.
///
/// [loadVehicles] отдаёт свежий список из Supabase (у экрана карты это
/// `MapNavigationController.fetchGarageVehicles`), [onAddVehicle] открывает
/// Гараж и резолвится после возврата — шторка перезагружает список.
Future<Vehicle?> showVehicleSelectorSheet(
  BuildContext context, {
  required Vehicle? selected,
  required Future<List<Vehicle>> Function() loadVehicles,
  required Future<void> Function() onAddVehicle,
}) {
  return showModalBottomSheet<Vehicle>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => VehicleSelectorSheet(
      selected: selected,
      loadVehicles: loadVehicles,
      onAddVehicle: onAddVehicle,
    ),
  );
}

class VehicleSelectorSheet extends StatefulWidget {
  final Vehicle? selected;
  final Future<List<Vehicle>> Function() loadVehicles;
  final Future<void> Function() onAddVehicle;

  const VehicleSelectorSheet({
    super.key,
    required this.selected,
    required this.loadVehicles,
    required this.onAddVehicle,
  });

  @override
  State<VehicleSelectorSheet> createState() => _VehicleSelectorSheetState();
}

class _VehicleSelectorSheetState extends State<VehicleSelectorSheet> {
  static const Color _accent = Color(0xFFFF6D1F); // фирменный deepOrange-акцент

  late Future<List<Vehicle>> _vehiclesFuture;
  Vehicle? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.selected;
    _vehiclesFuture = widget.loadVehicles();
  }

  void _reload() {
    setState(() {
      _vehiclesFuture = widget.loadVehicles();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Ручка шторки
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'На чём едем?',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              Flexible(
                child: FutureBuilder<List<Vehicle>>(
                  future: _vehiclesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (snapshot.hasError) {
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.cloud_off,
                              size: 40,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Не удалось загрузить гараж.\nПопробуйте ещё раз.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: _reload,
                              child: const Text('Обновить'),
                            ),
                          ],
                        ),
                      );
                    }

                    final vehicles = snapshot.data ?? const <Vehicle>[];
                    if (vehicles.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.pedal_bike,
                              size: 44,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                            const SizedBox(height: 8),
                            const Text('Гараж пуст — добавьте первую технику'),
                          ],
                        ),
                      );
                    }

                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: vehicles.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final vehicle = vehicles[index];
                        final isSelected =
                            _selected != null && _selected!.id == vehicle.id;
                        return _VehicleCard(
                          vehicle: vehicle,
                          isSelected: isSelected,
                          accent: _accent,
                          onTap: () => Navigator.pop(context, vehicle),
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  await widget.onAddVehicle();
                  if (mounted) _reload();
                },
                icon: const Icon(Icons.add),
                label: const Text('Добавить технику в Гараж'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _accent,
                  side: BorderSide(color: _accent.withValues(alpha: 0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Провайдер фото техники (только http-ссылки) или null.
DecorationImage? _photoProvider(Vehicle vehicle) {
  final url = vehicle.photoUrl;
  if (url == null ||
      !(url.startsWith('http://') || url.startsWith('https://'))) {
    return null;
  }
  return DecorationImage(image: NetworkImage(url), fit: BoxFit.cover);
}

class _VehicleCard extends StatelessWidget {
  final Vehicle vehicle;
  final bool isSelected;
  final Color accent;
  final VoidCallback onTap;

  const _VehicleCard({
    required this.vehicle,
    required this.isSelected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected
          ? accent.withValues(alpha: 0.08)
          : Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected
                  ? accent
                  : Theme.of(context).colorScheme.outlineVariant,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              // Фото техники (если загружено), иначе иконка типа.
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isSelected
                      ? accent.withValues(alpha: 0.15)
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                  image: _photoProvider(vehicle),
                ),
                child: _photoProvider(vehicle) == null
                    ? Icon(
                        vehicleIconFor(vehicle.transportType),
                        color: isSelected
                            ? accent
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        size: 24,
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      vehicle.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: isSelected
                            ? accent
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${vehicleTypeLabel(vehicle)}'
                      '${vehicle.wheelSize > 0 ? ' • ${vehicle.wheelSize.toStringAsFixed(0)}"' : ''}'
                      ' • пробег ${vehicle.totalDistance.toStringAsFixed(0)} км',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // Галочка выбранной техники
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: isSelected
                    ? const Icon(
                        Icons.check_circle,
                        key: ValueKey(true),
                        color: Color(0xFFFF6D1F),
                        size: 24,
                      )
                    : Icon(
                        Icons.radio_button_unchecked,
                        key: ValueKey(false),
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        size: 22,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
