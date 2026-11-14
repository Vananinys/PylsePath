import 'package:flutter/material.dart';

import '../controllers/map_navigation_controller.dart' show SportMode;
import '../models/vehicle.dart';
import '../ui/activity_design.dart';

class WorkoutPreparationPanel extends StatelessWidget {
  const WorkoutPreparationPanel({
    super.key,
    required this.vehicle,
    required this.mode,
    required this.onMode,
    required this.onVehicle,
    required this.autoPause,
    required this.onAutoPause,
    required this.onStart,
    required this.onClose,
    required this.enabled,
    this.route,
    this.onRoute,
    this.readiness,
    this.group,
    this.options,
    this.summary,
    this.startLabel = 'Начать тренировку',
  });
  final Vehicle? vehicle;
  final SportMode mode;
  final ValueChanged<SportMode> onMode;
  final VoidCallback onVehicle, onStart, onClose;
  final bool autoPause, enabled;
  final ValueChanged<bool> onAutoPause;
  final String? route, summary;
  final String startLabel;
  final VoidCallback? onRoute;
  final Widget? readiness, group, options;

  @override
  Widget build(BuildContext context) => ActivityDesign(
    builder: (context) {
      final theme = Theme.of(context), colors = theme.colorScheme;
      final onFoot = mode != SportMode.vehicle;
      return Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: .12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      onFoot
                          ? Icons.directions_walk_rounded
                          : Icons.directions_bike_rounded,
                      color: colors.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ваша тренировка',
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          'Настройте и начните запись',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    tooltip: 'Свернуть подготовку',
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ActivitySectionHeading('Активность'),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: false,
                          icon: Icon(Icons.directions_bike_outlined),
                          label: Text('Транспорт'),
                        ),
                        ButtonSegment(
                          value: true,
                          icon: Icon(Icons.directions_walk_outlined),
                          label: Text('Пешком и бег'),
                        ),
                      ],
                      selected: {onFoot},
                      showSelectedIcon: false,
                      onSelectionChanged: enabled
                          ? (value) => onMode(
                              value.single
                                  ? SportMode.walking
                                  : SportMode.vehicle,
                            )
                          : null,
                      style: SegmentedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                    if (onFoot) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final item in SportMode.values.where(
                            (v) => v != SportMode.vehicle,
                          ))
                            ChoiceChip(
                              label: Text(item.label),
                              selected: mode == item,
                              onSelected: enabled ? (_) => onMode(item) : null,
                            ),
                        ],
                      ),
                    ] else ...[
                      const SizedBox(height: 12),
                      _setting(
                        context,
                        icon: Icons.pedal_bike_outlined,
                        title: vehicle?.name ?? 'Без привязки к технике',
                        subtitle: vehicle == null
                            ? 'Выберите велосипед или другой транспорт'
                            : 'Техника из вашего гаража',
                        onTap: enabled ? onVehicle : null,
                      ),
                    ],
                    if (readiness != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: readiness,
                        ),
                      ),
                    _setting(
                      context,
                      icon: Icons.route_outlined,
                      title: route == null
                          ? 'Свободная тренировка'
                          : 'Маршрут выбран',
                      subtitle:
                          route ?? 'Запись без заранее построенного маршрута',
                      onTap: enabled ? onRoute : null,
                      action: route == null ? 'Добавить' : 'Изменить',
                    ),
                    if (group != null) ...[const SizedBox(height: 18), group!],
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: ExpansionTile(
                        key: const PageStorageKey('pre-ride-options'),
                        leading: Icon(
                          Icons.tune_rounded,
                          size: 21,
                          color: colors.primary,
                        ),
                        title: const Text(
                          'Параметры записи',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          summary ?? 'Цель, интервалы и приватность',
                          style: theme.textTheme.bodySmall,
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          12,
                          0,
                          12,
                          12,
                        ),
                        children: [
                          SwitchListTile.adaptive(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            title: const Text(
                              'Автопауза',
                              style: TextStyle(fontSize: 14),
                            ),
                            subtitle: const Text(
                              'При остановке время движения не растёт',
                              style: TextStyle(fontSize: 12),
                            ),
                            value: autoPause,
                            onChanged: enabled ? onAutoPause : null,
                          ),
                          if (options != null) options!,
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.outlineVariant)),
              ),
              child: FilledButton.icon(
                onPressed: enabled ? onStart : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(startLabel),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _setting(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    String? action,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
        leading: Icon(icon, color: colors.primary, size: 23),
        title: Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: onTap == null
            ? null
            : action == null
            ? const Icon(Icons.chevron_right, size: 20)
            : Text(
                action,
                style: TextStyle(
                  fontSize: 12,
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
        onTap: onTap,
      ),
    );
  }
}
