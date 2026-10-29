import 'package:flutter/material.dart';

/// Saving geometry and downloading map coverage are independent guarantees.
class RouteOfflineReadiness extends StatelessWidget {
  const RouteOfflineReadiness({
    super.key,
    required this.saved,
    required this.hasGeometry,
    required this.hasInstructions,
    required this.onSave,
    required this.onOpenMaps,
  });
  final bool saved, hasGeometry, hasInstructions;
  final VoidCallback onSave, onOpenMaps;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 8),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Перед поездкой без сети',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            saved && hasGeometry
                ? '✓ Маршрут сохранён на устройстве'
                : 'Маршрут ещё нужно сохранить на устройстве',
          ),
          Text(
            hasGeometry && hasInstructions
                ? 'Инструкции по текущему пути доступны; для офлайн-поездки сохраните маршрут.'
                : 'Поворотные инструкции не подтверждены. Ориентируйтесь по линии трека.',
          ),
          const SizedBox(height: 6),
          const Text(
            'Карты вдоль всего маршрута: покрытие не проверено. Просмотренные тайлы и скачанная область не гарантируют карту на всём пути.',
          ),
          const Text(
            'Пересчёт по дорогам требует интернета. Без сети сохраняйте текущий трек и возвращайтесь к его линии.',
          ),
          Wrap(
            spacing: 8,
            children: [
              if (!saved && hasGeometry)
                TextButton.icon(
                  onPressed: onSave,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('Сохранить маршрут'),
                ),
              TextButton.icon(
                onPressed: onOpenMaps,
                icon: const Icon(Icons.download_for_offline_outlined),
                label: const Text('Офлайн-карты'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
