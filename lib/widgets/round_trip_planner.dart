import 'package:flutter/material.dart';

import '../models/activity_type.dart';

class RoundTripRequest {
  const RoundTripRequest(this.distanceKm, this.bearing, this.activity);
  final double distanceKm;
  final double bearing;
  final ActivityType activity;
}

class RoundTripPlanner extends StatefulWidget {
  const RoundTripPlanner({super.key, required this.activity});
  final ActivityType activity;

  @override
  State<RoundTripPlanner> createState() => _RoundTripPlannerState();
}

class _RoundTripPlannerState extends State<RoundTripPlanner> {
  double _km = 20;
  double _bearing = 0;
  late ActivityType _activity = widget.activity;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Круговой маршрут',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Старт и финиш — ваше текущее место. Дистанция примерная: итог зависит от доступных дорог и троп.',
          ),
          const SizedBox(height: 20),
          Text(
            'Примерно ${_km.round()} км',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Slider(
            value: _km,
            min: 2,
            max: 100,
            divisions: 98,
            label: '${_km.round()} км',
            onChanged: (value) => setState(() => _km = value),
          ),
          DropdownButtonFormField<ActivityType>(
            isExpanded: true,
            initialValue: _activity,
            decoration: const InputDecoration(labelText: 'Активность'),
            items: ActivityType.values
                .map(
                  (activity) => DropdownMenuItem(
                    value: activity,
                    child: Text(
                      activity.label,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) setState(() => _activity = value);
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<double>(
            isExpanded: true,
            initialValue: _bearing,
            decoration: const InputDecoration(
              labelText: 'В какую сторону поехать',
            ),
            items: const [
              DropdownMenuItem(value: 0, child: Text('На север')),
              DropdownMenuItem(value: 90, child: Text('На восток')),
              DropdownMenuItem(value: 180, child: Text('На юг')),
              DropdownMenuItem(value: 270, child: Text('На запад')),
            ],
            onChanged: (value) => setState(() => _bearing = value ?? 0),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.loop),
            label: const Text('Построить круг'),
            onPressed: () => Navigator.pop(
              context,
              RoundTripRequest(_km, _bearing, _activity),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Расчёт онлайн: координаты маршрута передаются FOSSGIS. Для другого варианта измените направление.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
  );
}
