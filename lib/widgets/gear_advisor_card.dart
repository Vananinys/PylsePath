import 'package:flutter/material.dart';

import '../models/vehicle.dart';

class GearAdvisorCard extends StatefulWidget {
  const GearAdvisorCard({
    super.key,
    required this.vehicle,
    required this.speedKmh,
    required this.onConfigure,
    this.planning = false,
    this.compact = false,
  });
  final Vehicle? vehicle;
  final double speedKmh;
  final bool planning;
  final bool compact;
  final VoidCallback onConfigure;
  @override
  State<GearAdvisorCard> createState() => _GearAdvisorCardState();
}

class _GearAdvisorCardState extends State<GearAdvisorCard> {
  double _plannedSpeed = 18;
  @override
  Widget build(BuildContext context) {
    final d = widget.vehicle?.drivetrain;
    final speed = widget.planning ? _plannedSpeed : widget.speedKmh;
    final gear = d?.suggest(speed);
    if (widget.compact) {
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(
          Icons.settings_suggest_outlined,
          size: 20,
          color: Colors.deepOrange,
        ),
        title: Text(
          gear?.label ?? 'Подсказка передачи',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: const Icon(Icons.info_outline, size: 20),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          useSafeArea: true,
          isScrollControlled: true,
          builder: (_) => SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: GearAdvisorCard(
                vehicle: widget.vehicle,
                speedKmh: widget.speedKmh,
                onConfigure: widget.onConfigure,
                planning: widget.planning,
              ),
            ),
          ),
        ),
      );
    }
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.settings_suggest_outlined,
                  color: Colors.deepOrange,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Подсказка передачи · эксперимент',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  tooltip: 'Настроить трансмиссию',
                  onPressed: widget.onConfigure,
                  icon: const Icon(Icons.tune, size: 20),
                ),
              ],
            ),
            if (d == null || !d.gearsConfigured)
              TextButton(
                onPressed: widget.onConfigure,
                child: const Text(
                  'Выберите велосипед и укажите его звёзды в гараже',
                ),
              )
            else ...[
              Text('${widget.vehicle!.name} · ${d.speeds} передач'),
              if (widget.planning) ...[
                Text('Плановый темп: ${_plannedSpeed.round()} км/ч'),
                Slider(
                  value: _plannedSpeed,
                  min: 5,
                  max: 50,
                  divisions: 45,
                  label: '${_plannedSpeed.round()} км/ч',
                  onChanged: (v) => setState(() => _plannedSpeed = v),
                ),
              ],
              if (gear != null) ...[
                Text(
                  gear.label,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  'При ${speed.toStringAsFixed(1)} км/ч ≈ ${gear.cadence.round()} об/мин',
                ),
              ] else
                const Text('Подсказка появится при движении от 3 км/ч'),
              Text(
                'Цель: ${d.targetCadence.round()} об/мин. Передние звёзды: от малой к большой; задние: от большой к малой.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                'Расчёт по скорости и настройкам велосипеда. Текущая передача, каденс, нагрузка и уклон не измеряются.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
