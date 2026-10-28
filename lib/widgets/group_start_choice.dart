import 'package:flutter/material.dart';

import '../services/group_ride_service.dart';
import '../models/group_coordination.dart';

/// Membership is preparation; the choice below opts one workout into a room.
class GroupStartChoice extends StatelessWidget {
  const GroupStartChoice({
    super.key,
    required this.service,
    required this.selectedRoomId,
    required this.onChanged,
    required this.onManage,
    this.onUseRoute,
    this.disabled = false,
    this.sharesLocation = false,
  });
  final GroupRideService service;
  final String? selectedRoomId;
  final ValueChanged<String?> onChanged;
  final VoidCallback onManage;
  final VoidCallback? onUseRoute;
  final bool disabled;
  final bool sharesLocation;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final room = service.activeRoomId;
      final selected = selectedRoomId != null;
      final valid = selected && selectedRoomId == room;
      final colors = Theme.of(context).colorScheme;
      Widget option(bool group, IconData icon, String label) => Expanded(
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Material(
            color: selected == group
                ? colors.primaryContainer
                : colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: disabled
                  ? null
                  : () => group && room == null
                        ? onManage()
                        : onChanged(group ? room : null),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                child: Column(
                  children: [
                    Icon(
                      icon,
                      color: selected == group
                          ? colors.onPrimaryContainer
                          : colors.onSurfaceVariant,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Как поедем?',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              option(false, Icons.person_outline, 'Без группы'),
              option(true, Icons.groups_outlined, 'В группе'),
            ],
          ),
          if (valid) ...[
            Text(
              '${service.title} · ${service.members.length} участников',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              'Готовы ${service.members.where((m) => service.coordination.readiness[m.userId] == GroupReadiness.ready).length} из ${service.members.length}. Запустится только ваша запись.',
              style: const TextStyle(fontSize: 12),
            ),
            Text(
              sharesLocation
                  ? 'Позиция открыта группе и друзьям. Доступ можно изменить в настройках тренировки.'
                  : 'Позиция скрыта. Группа увидит статус и прогресс вашей поездки.',
              style: const TextStyle(fontSize: 12),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: disabled ? null : onManage,
                  child: const Text('Открыть группу'),
                ),
                if (service.route != null && onUseRoute != null)
                  TextButton.icon(
                    onPressed: disabled ? null : onUseRoute,
                    icon: const Icon(Icons.route_outlined),
                    label: const Text('Маршрут группы'),
                  ),
              ],
            ),
          ] else if (selected)
            Text(
              'Группа изменилась. Выберите «В группе» заново или поезжайте самостоятельно.',
              style: TextStyle(color: colors.error),
            )
          else if (room != null)
            Text(
              'Группа «${service.title}» готова к выбору.',
              style: const TextStyle(fontSize: 12),
            )
          else
            TextButton(
              onPressed: disabled ? null : onManage,
              child: const Text('Создать группу или войти по коду'),
            ),
        ],
      );
    },
  );
}
