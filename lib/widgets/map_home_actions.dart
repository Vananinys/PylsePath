import 'package:flutter/material.dart';

/// The two primary map journeys. Secondary actions live in the planner/menu.
class MapHomeActions extends StatelessWidget {
  const MapHomeActions({
    super.key,
    required this.onWorkout,
    required this.onRoute,
  });
  final VoidCallback? onWorkout;
  final VoidCallback? onRoute;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    elevation: 6,
    borderRadius: BorderRadius.circular(24),
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: _action(
              context,
              'Начать тренировку',
              Icons.play_circle_outline,
              onWorkout,
              true,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _action(
              context,
              'Построить маршрут',
              Icons.route_outlined,
              onRoute,
              false,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _action(
    BuildContext context,
    String label,
    IconData icon,
    VoidCallback? callback,
    bool primary,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      child: Material(
        color: primary ? colors.primary : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: callback,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: primary ? colors.onPrimary : colors.onSurface,
                  size: 24,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: primary ? colors.onPrimary : colors.onSurface,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum RouteEntryAction { search, map, saved, roundTrip }

Future<RouteEntryAction?> showRouteEntrySheet(BuildContext context) =>
    showModalBottomSheet<RouteEntryAction>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  'Построить маршрут',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('Сначала выберите, куда хотите добраться.'),
              ),
              const SizedBox(height: 12),
              for (final option in const [
                (
                  RouteEntryAction.search,
                  Icons.search,
                  'Найти место',
                  'Адрес или название · рядом и в другом городе',
                ),
                (
                  RouteEntryAction.map,
                  Icons.pin_drop_outlined,
                  'Выбрать на карте',
                  'Удерживайте нужное место на карте',
                ),
                (
                  RouteEntryAction.saved,
                  Icons.bookmarks_outlined,
                  'Сохранённые маршруты',
                  'Выбрать готовый маршрут',
                ),
                (
                  RouteEntryAction.roundTrip,
                  Icons.loop,
                  'Круговой маршрут',
                  'Вернуться в точку старта',
                ),
              ])
                ListTile(
                  leading: Icon(option.$2),
                  title: Text(option.$3),
                  subtitle: Text(option.$4),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, option.$1),
                ),
            ],
          ),
        ),
      ),
    );
