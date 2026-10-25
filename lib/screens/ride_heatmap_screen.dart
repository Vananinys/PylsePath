import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/workout_history_repository.dart';
import '../services/offline_maps_service.dart';
import '../services/training_heatmap.dart';
import '../widgets/training_heat_layer.dart';
import '../widgets/map_credits.dart';
export 'heatmap_explorer_screen.dart' show RideHeatmapScreen;

class LegacyRideHeatmapScreen extends StatefulWidget {
  const LegacyRideHeatmapScreen({super.key});
  @override
  State<LegacyRideHeatmapScreen> createState() => _RideHeatmapScreenState();
}

class _RideHeatmapScreenState extends State<LegacyRideHeatmapScreen> {
  bool _loading = true,
      _consent = false,
      _saving = false,
      _consentLoaded = false;
  int _mode = 1, _days = 0;
  int _revision = 0;
  LatLng _center = const LatLng(52.54, 85.2);
  LatLngBounds? _bounds;
  String _status = 'Загрузка тренировок…';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = WorkoutHistoryRepository();
    await repo.load();
    final points = repo.workoutHistory.expand((r) => r.routePoints).toList();
    bool consent = false, loaded = false;
    try {
      consent = await TrainingHeatmap.consent();
      loaded = true;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _consent = consent;
      _consentLoaded = loaded;
      _loading = false;
      if (points.isNotEmpty) {
        _center = points.last;
        _bounds = LatLngBounds.fromPoints(points);
      }
    });
  }

  Future<void> _setConsent(bool value) async {
    if (value) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Участвовать в публичной карте?'),
          content: const SingleChildScrollView(
            child: Text(
              'Будут обработаны GPS-треки ваших облачных тренировок, включая историю. '
              'В публичный слой попадут только ячейки примерно 300–550 м, посещённые минимум 3 участниками. '
              'Начало и конец каждого участка трека в радиусе 1 км скрываются. Данные появляются не раньше чем через сутки. '
              'Имена, точные треки и время не публикуются. Выключение удалит ваш вклад. Это снижает риск раскрытия мест, но не даёт абсолютной анонимности.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Участвовать'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      await TrainingHeatmap.setConsent(value);
      if (mounted)
        setState(() {
          _consent = value;
          _revision++;
          _status = value
              ? 'Вклад сохранён. Новые тренировки появятся после задержки.'
              : 'Ваш вклад удалён из публичной карты.';
        });
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось сохранить согласие. Проверьте интернет и повторите.',
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Тепловые карты')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                      value: 1,
                      icon: Icon(Icons.person_outline),
                      label: Text('Моя'),
                    ),
                    ButtonSegment(
                      value: 2,
                      icon: Icon(Icons.groups_outlined),
                      label: Text('Публичная'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (v) => setState(() {
                    _mode = v.first;
                    _status = 'Загрузка…';
                  }),
                ),
              ),
              if (_mode == 1)
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final entry in {
                        0: 'Всё время',
                        30: '30 дней',
                        90: '90 дней',
                        365: 'Год',
                      }.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(entry.value),
                            selected: _days == entry.key,
                            onSelected: (_) => setState(() {
                              _days = entry.key;
                              _status = 'Загрузка…';
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
              if (_mode == 2)
                SwitchListTile(
                  dense: true,
                  title: const Text('Мои тренировки в публичной карте'),
                  subtitle: Text(
                    _consentLoaded ? 'Добровольно · без имён и точных треков' : 'Согласие не загрузилось. Откройте экран заново при наличии сети.',
                  ),
                  value: _consent,
                  onChanged: _saving || !_consentLoaded ? null : _setConsent,
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Text(_status, style: const TextStyle(fontSize: 12)),
              ),
              Expanded(
                child: FlutterMap(
                  options: MapOptions(
                    initialCenter: _center,
                    initialZoom: 12,
                    initialCameraFit: _bounds == null
                        ? null
                        : CameraFit.bounds(
                            bounds: _bounds!,
                            padding: const EdgeInsets.all(35),
                            maxZoom: 15,
                          ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      tileProvider: OfflineMapsService.tileProvider(),
                      userAgentPackageName: 'com.example.pulsepath',
                    ),
                    TrainingHeatLayer(
                      key: ValueKey(_revision),
                      mode: _mode,
                      days: _days,
                      onStatus: (value) {
                        if (mounted) setState(() => _status = value);
                      },
                    ),
                    const Align(
                      alignment: Alignment.bottomRight,
                      child: MapCredits(),
                    ),
                  ],
                ),
              ),
              const SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Жёлтый → оранжевый: растёт число тренировок. Личная карта видна только вам.',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
  );
}
