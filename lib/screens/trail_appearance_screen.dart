import 'package:flutter/material.dart';

import '../data/trail_appearance.dart';
import '../models/activity_type.dart';
import '../widgets/activity_trail_layer.dart';

class TrailAppearanceScreen extends StatefulWidget {
  const TrailAppearanceScreen({super.key, this.appearance});
  final TrailAppearance? appearance;
  @override
  State<TrailAppearanceScreen> createState() => _TrailAppearanceScreenState();
}

class _TrailAppearanceScreenState extends State<TrailAppearanceScreen> {
  late final prefs = widget.appearance ?? TrailAppearance.instance;
  String _example = 'hiking';
  String? _error;
  ActivityType get _activity =>
      ActivityType.values.where((v) => v.name == _example).firstOrNull ??
      ActivityType.cycling;
  Future<void> _change(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted)
        setState(
          () => _error = 'Не удалось сохранить оформление. Предыдущий выбор сохранён; повторите попытку.',
        );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('След на карте')),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: prefs,
        builder: (context, _) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TrailStylePreview(
                appearance: prefs,
                activity: _activity,
                transport: _example == 'scooter' ? 'Самокат' : null,
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Ваш след',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 10),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            initialValue: _example,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Пример активности',
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              for (final value in ActivityType.values)
                                DropdownMenuItem(
                                  value: value.name,
                                  child: Text(value.label),
                                ),
                              const DropdownMenuItem(
                                value: 'scooter',
                                child: Text('Самокат'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null)
                                setState(() => _example = value);
                            },
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Выбранный рисунок применяется к маршрутам, тренировке, вашему шлейфу вне тренировки и шлейфам друзей. Это оформление GPS-пути, а не измеренные шаги.',
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Text(
                    'Рисунок следа',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final style in TrailStyle.values)
                        ChoiceChip(
                          avatar: Icon(style.icon, size: 18),
                          label: Text(style.label),
                          selected: prefs.style == style,
                          onSelected: (_) =>
                              _change(() => prefs.update(pattern: style)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Цвет следа',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (var i = 0; i < TrailAppearance.colors.length; i++)
                        Semantics(
                          label: 'Цвет следа ${i + 1}',
                          selected: prefs.colorIndex == i,
                          button: true,
                          child: InkWell(
                            onTap: () => _change(() => prefs.update(color: i)),
                            customBorder: const CircleBorder(),
                            child: CircleAvatar(
                              backgroundColor: TrailAppearance.colors[i],
                              radius: 23,
                              child: prefs.colorIndex == i
                                  ? const Icon(Icons.check, color: Colors.white)
                                  : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (prefs.style != TrailStyle.line) ...[
                    Text('Размер отпечатка · ${prefs.size.round()}'),
                    Slider(
                      value: prefs.size,
                      min: 6,
                      max: 20,
                      divisions: 14,
                      label: prefs.size.round().toString(),
                      onChanged: prefs.style == TrailStyle.line
                          ? null
                          : (v) => _change(() => prefs.update(markerSize: v)),
                    ),
                    Text(
                      'Расстояние между отпечатками · ${prefs.spacing.round()}',
                    ),
                    Slider(
                      value: prefs.spacing,
                      min: 16,
                      max: 64,
                      divisions: 12,
                      label: prefs.spacing.round().toString(),
                      onChanged: (v) => _change(() => prefs.update(density: v)),
                    ),
                  ] else
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Толщина обычной линии настраивается в разделе «Карта и навигация».',
                      ),
                    ),
                  Text('Непрозрачность · ${(prefs.opacity * 100).round()}%'),
                  Slider(
                    value: prefs.opacity,
                    min: .25,
                    max: 1,
                    divisions: 15,
                    onChanged: (v) => _change(() => prefs.update(alpha: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Линия под отпечатками'),
                    subtitle: const Text('Помогает видеть непрерывный путь'),
                    value: prefs.guide,
                    onChanged: (v) => _change(() => prefs.update(showGuide: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('На маршрутах и в истории'),
                    value: prefs.onRoutes,
                    onChanged: (v) => _change(() => prefs.update(routes: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Во время записи тренировки'),
                    value: prefs.onRecording,
                    onChanged: (v) => _change(() => prefs.update(recording: v)),
                  ),
                  const Text(
                    'При отдалении карты остаётся обычная линия. Разрывы GPS сохраняются. Настройки действуют только на этом устройстве и не меняют маршрут получателя.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => _change(() => prefs.update(reset: true)),
                    child: const Text('Стандартное оформление'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
