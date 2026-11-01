import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../controllers/map_navigation_controller.dart';
import '../services/laboratory_motion_source.dart';

/// Controls remain on the actual map, above the ordinary route/workout UI.
class LaboratoryControls extends StatefulWidget {
  const LaboratoryControls({
    super.key,
    required this.controller,
    required this.mapCenter,
  });
  final MapNavigationController controller;
  final LatLng Function() mapCenter;
  @override
  State<LaboratoryControls> createState() => _LaboratoryControlsState();
}

class _LaboratoryControlsState extends State<LaboratoryControls>
    with WidgetsBindingObserver {
  bool expanded = false, busy = false;
  double panelOffset = 0;
  LaboratoryMotionSource get source => widget.controller.laboratory!;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) source.stopMovement();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> restoreDraft() async {
    final controller = widget.controller;
    if (controller.isWorkoutActive || controller.isWorkoutPaused)
      throw StateError('Сначала завершите текущую тестовую запись');
    final drafts = await controller.laboratoryStore.drafts();
    if (!mounted) return;
    if (drafts.isEmpty) throw StateError('Прерванных тестовых записей нет');
    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Восстановить тестовую запись'),
        children: [
          for (var i = 0; i < drafts.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, i),
              child: Text(
                '${drafts[i].startedAt.toLocal()} · ${drafts[i].path.length} точек',
              ),
            ),
        ],
      ),
    );
    if (!mounted || chosen == null || !controller.laboratoryActive) return;
    controller.restoreInterruptedWorkout(drafts[chosen]);
    if (drafts[chosen].path.isNotEmpty) source.point = drafts[chosen].path.last;
    source.stopMovement();
  }

  Future<void> results() async {
    final records = await widget.controller.laboratoryStore.results();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Лабораторные записи'),
        content: SizedBox(
          width: 400,
          child: records.isEmpty
              ? const Text(
                  'Завершите тренировку обычной кнопкой сохранения. Здесь появится её фактическая запись.',
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final ride in records)
                      ListTile(
                        title: Text(ride.title),
                        subtitle: Text(
                          '${ride.distanceMeters?.toStringAsFixed(0)} м · ${ride.durationSeconds} с · ${ride.routePoints.length} точек',
                        ),
                        trailing: IconButton(
                          tooltip: 'Копировать полную запись JSON',
                          icon: const Icon(Icons.copy),
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(
                                text: jsonEncode({
                                  'source': 'laboratory',
                                  'ride': ride.toJson(),
                                }),
                              ),
                            );
                            if (context.mounted)
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Тестовая запись скопирована'),
                                ),
                              );
                          },
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: source,
    builder: (context, _) => Transform.translate(
      offset: Offset(0, panelOffset),
      child: Card(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .55,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onPanUpdate: (details) => setState(
                      () => panelOffset = (panelOffset + details.delta.dy)
                          .clamp(0, MediaQuery.sizeOf(context).height * .25),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.drag_indicator),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text(
                            'ЛАБОРАТОРИЯ · тестовый GPS',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        IconButton(
                          tooltip: expanded
                              ? 'Свернуть управление'
                              : 'Управление движением',
                          onPressed: () => setState(() => expanded = !expanded),
                          icon: Icon(
                            expanded ? Icons.expand_less : Icons.expand_more,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () {
                                source.moving = !source.moving;
                                source.emit();
                              },
                        icon: Icon(
                          source.moving ? Icons.stop : Icons.play_arrow,
                        ),
                        label: Text(source.moving ? 'Стоять' : 'Ехать'),
                      ),
                      Text(
                        '${source.speedKmh.round()} км/ч · ${source.heading.round()}°',
                      ),
                    ],
                  ),
                  if (expanded) ...[
                    const Text(
                      'Обычные кнопки карты запускают навигацию и запись. Результаты рассчитывает рабочий контроллер. Записи — отдельно, без XP и отправки друзьям.',
                    ),
                    Text('Скорость: ${source.speedKmh.round()} км/ч'),
                    Slider(
                      value: source.speedKmh,
                      min: 0,
                      max: 100,
                      onChanged: (v) {
                        source.speedKmh = v;
                        source.emit();
                      },
                    ),
                    Text(
                      'Курс: ${source.heading.round()}° · 0° север, 90° восток',
                    ),
                    Slider(
                      value: source.heading,
                      min: 0,
                      max: 360,
                      onChanged: (v) {
                        source.steer(v);
                      },
                    ),
                    Text('Высота: ${source.altitude.round()} м'),
                    Slider(
                      value: source.altitude,
                      min: 0,
                      max: 3000,
                      onChanged: (v) {
                        source.altitude = v;
                        source.emit();
                      },
                    ),
                    Text('Погрешность: ${source.accuracy.round()} м'),
                    Slider(
                      value: source.accuracy,
                      min: 1,
                      max: 150,
                      onChanged: (v) {
                        source.accuracy = v;
                        source.emit();
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Подача GPS-наблюдений'),
                      subtitle: const Text(
                        'При выключении наблюдения прекращаются. Потерю сигнала определяет обычный контроль свежести.',
                      ),
                      value: source.gpsAvailable,
                      onChanged: (v) {
                        source.gpsAvailable = v;
                        source.emit();
                      },
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: busy
                              ? null
                              : () => run(() async {
                                  if (widget
                                      .controller
                                      .routeSegmentStarts
                                      .isNotEmpty)
                                    throw StateError(
                                      'Для трека с разрывами выберите непрерывный участок',
                                    );
                                  source.followRoute(
                                    widget.controller.routePoints,
                                  );
                                }),
                          child: Text(
                            source.followingRoute
                                ? 'Движение по маршруту'
                                : 'Ехать по маршруту',
                          ),
                        ),
                        OutlinedButton(
                          onPressed: busy ? null : () => run(restoreDraft),
                          child: const Text('Восстановить тест'),
                        ),

                        OutlinedButton(
                          onPressed:
                              widget.controller.isWorkoutActive ||
                                  widget.controller.isWorkoutPaused
                              ? null
                              : () {
                                  source.point = widget.mapCenter();
                                  source.emit();
                                },
                          child: const Text('Перенести в центр карты'),
                        ),
                        OutlinedButton(
                          onPressed: busy ? null : () => run(results),
                          child: const Text('Записи / JSON'),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => run(widget.controller.endLaboratory),
                          child: const Text('Вернуть настоящий GPS'),
                        ),
                      ],
                    ),
                    const Text(
                      'Сеть, маршрутизация, карты и голос работают по-настоящему. Для офлайн-проверки отключите сеть телефона. Это не испытание физического GPS, датчика шагов, батареи и работы Android в фоне.',
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
