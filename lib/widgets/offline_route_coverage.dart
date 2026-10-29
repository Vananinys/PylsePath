import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/offline_maps_service.dart';
import '../screens/offline_maps_screen.dart';

class OfflineRouteCoverage extends StatefulWidget {
  const OfflineRouteCoverage({super.key, required this.points});
  final List<LatLng> points;
  @override
  State<OfflineRouteCoverage> createState() => _OfflineRouteCoverageState();
}

class _OfflineRouteCoverageState extends State<OfflineRouteCoverage> {
  Future<({int present, int required})?>? _check;
  @override
  void initState() {
    super.initState();
    _check = OfflineMapsService.checkRoute(widget.points);
  }

  @override
  void didUpdateWidget(OfflineRouteCoverage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.points, widget.points))
      _check = OfflineMapsService.checkRoute(widget.points);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      FutureBuilder<({int present, int required})?>(
        future: _check,
        builder: (ctx, snapshot) {
          final value = snapshot.data;
          final message = snapshot.connectionState != ConnectionState.done
              ? 'Проверяем наличие карт на всём пути…'
              : snapshot.hasError
              ? 'Покрытие не подтверждено: область слишком большая или не удалось прочитать кэш.'
              : value == null
              ? 'Хранилище офлайн-карт недоступно.'
              : value.present == value.required
              ? 'Карты 13–16: все ${value.required} тайлов найдены при последней проверке.'
              : 'Карты 13–16: найдено ${value.present} из ${value.required} тайлов. Покрытие неполное.';
          return Text(message);
        },
      ),
      Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: () => setState(
              () => _check = OfflineMapsService.checkRoute(widget.points),
            ),
            child: const Text('Перепроверить карты'),
          ),
          TextButton.icon(
            icon: const Icon(Icons.download_for_offline_outlined),
            label: const Text('Подготовить карты маршрута'),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => OfflineMapsScreen(routePoints: widget.points),
                ),
              );
              if (mounted)
                setState(
                  () => _check = OfflineMapsService.checkRoute(widget.points),
                );
            },
          ),
        ],
      ),
      const Text(
        'Проверяется область всего пути с запасом, масштабы 13–16. Это растровая карта, не дорожный граф для пересчёта.',
      ),
      const Text(
        'Чтобы видеть именно проверенные здесь карты, включите «Только офлайн» на экране офлайн-карт. Без настроенного источника автоматический офлайн-режим сохраняет текущий слой и использует его просмотренные тайлы.',
      ),
    ],
  );
}
