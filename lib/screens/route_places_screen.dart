import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/route_places_service.dart';
import '../data/saved_places_repository.dart';
import '../models/saved_place.dart';

class RoutePlacesScreen extends StatefulWidget {
  const RoutePlacesScreen({
    super.key,
    required this.points,
    this.onStop,
    this.progressMeters = 0,
  });
  final List<LatLng> points;
  final Future<void> Function(LatLng)? onStop;
  final double progressMeters;
  @override
  State<RoutePlacesScreen> createState() => _RoutePlacesScreenState();
}

class _RoutePlacesScreenState extends State<RoutePlacesScreen> {
  Future<List<RoutePlace>>? _result;
  bool _busy = false, _loading = false;
  final _saved = SavedPlacesRepository();
  void _load() {
    if (!_saved.isCurrent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Аккаунт изменился. Откройте маршрут заново.'),
        ),
      );
      return;
    }
    if (_loading) return;
    final request = RoutePlacesService().fetch(widget.points);
    setState(() {
      _loading = true;
      _result = request;
    });
    request.then<void>(
      (_) {
        if (mounted) setState(() => _loading = false);
      },
      onError: (Object _, StackTrace __) {
        if (mounted) setState(() => _loading = false);
      },
    );
  }

  Future<void> _act(Future<void> Function() action, String message) async {
    setState(() => _busy = true);
    try {
      if (!_saved.isCurrent) throw StateError('Аккаунт изменился');
      await action();
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось выполнить действие. Исходный маршрут сохранён, попробуйте ещё раз.',
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Места по пути')),
    body: SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Вода, кафе, велоремонт и отдых по данным OpenStreetMap. Полнота, доступность и часы работы не подтверждены. Расстояния — вдоль трека, съезд к месту указан по прямой, не как проверенный проезд.',
                  ),
                ),
                FilledButton(
                  onPressed: _busy || _loading ? null : _load,
                  child: const Text('Найти места по маршруту'),
                ),
                if (widget.onStop == null)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                      'Добавление остановки доступно при редактировании построенного маршрута. Для сохранённого трека или активной навигации сначала выберите режим изменения пути.',
                    ),
                  ),
              ],
            ),
          ),
          SliverFillRemaining(
            child: _result == null
                ? const Center(
                    child: Text(
                      'Поиск выполняется по вашему запросу и передаёт геометрию маршрута источнику мест.',
                    ),
                  )
                : FutureBuilder<List<RoutePlace>>(
                    future: _result,
                    builder: (ctx, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done)
                        return const Center(child: CircularProgressIndicator());
                      if (snapshot.hasError)
                        return const Center(
                          child: Text(
                            'Не удалось получить места. Возможны отсутствие сети, ограничение источника или слишком длинный трек (до 2000 точек). Это не означает, что мест по пути нет.',
                          ),
                        );
                      final places = (snapshot.data ?? [])
                          .where(
                            (p) => p.alongMeters >= widget.progressMeters - 20,
                          )
                          .toList();
                      if (places.isEmpty)
                        return const Center(
                          child: Text(
                            'Источник не вернул подходящих мест впереди. Его данные могут быть неполными.',
                          ),
                        );
                      return ListView.builder(
                        itemCount: places.length,
                        itemBuilder: (ctx, i) {
                          final p = places[i];
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    p.name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  Text(
                                    '${p.kind} · ${((p.alongMeters - widget.progressMeters).clamp(0, double.infinity) / 1000).toStringAsFixed(1)} км по треку · ${p.detourMeters.round()} м от линии',
                                  ),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _act(
                                                () => _saved.save(
                                                  SavedPlace(
                                                    name: p.name,
                                                    latitude: p.point.latitude,
                                                    longitude:
                                                        p.point.longitude,
                                                    kind: p.kind == 'Вода'
                                                        ? SavedPlaceKind.water
                                                        : SavedPlaceKind.other,
                                                  ),
                                                ),
                                                'Место сохранено на устройстве',
                                              ),
                                        child: const Text('Сохранить место'),
                                      ),
                                      if (widget.onStop != null)
                                        TextButton(
                                          onPressed: _busy
                                              ? null
                                              : () => _act(
                                                  () => widget.onStop!(p.point),
                                                  'Маршрут пересчитан с остановкой',
                                                ),
                                          child: const Text(
                                            'Добавить остановку',
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
