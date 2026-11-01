import 'package:flutter/material.dart';

import '../services/group_ride_service.dart';
import 'group_journey_panel.dart';
import 'section_intro.dart';

class GroupRideResultSheet extends StatelessWidget {
  const GroupRideResultSheet({
    super.key,
    required this.members,
    required this.service,
    required this.distanceKm,
    required this.minutes,
    required this.left,
    this.warning,
  });
  final List<GroupMember> members;
  final GroupRideService service;
  final double distanceKm;
  final int minutes;
  final bool left;
  final String? warning;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionIntro(
            icon: Icons.check_circle_outline,
            eyebrow: 'ЛИЧНЫЙ РЕЗУЛЬТАТ',
            title: 'Ваша тренировка сохранена',
            description: 'Запись сохранена на устройстве. Облачная синхронизация выполняется при доступной сети.',
          ),
          const SizedBox(height: 12),
          Text(
            '${distanceKm.toStringAsFixed(2)} км · $minutes мин',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Text(
            left ? 'Вы завершили участие. Остальные продолжают свой заезд.' : 'Вы завершили запись и остались в заезде. Для следующей тренировки создайте новый заезд.',
          ),
          if (warning != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(warning!),
              ),
            ),
          const SizedBox(height: 16),
          const Text('Участники · состояние при сохранении'),
          for (final member in members)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '${member.username}${member.userId == service.userId ? ' · вы' : ''}',
              ),
              subtitle: Text(
                member.userId == service.userId
                    ? 'Завершил тренировку\n${distanceKm.toStringAsFixed(2)} км · $minutes мин'
                    : '${participantStage(member, service)}\n${(member.distanceMeters / 1000).toStringAsFixed(2)} км · ${Duration(seconds: member.durationSeconds).inMinutes} мин',
              ),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'workout'),
            child: const Text('Посмотреть тренировку'),
          ),
          if (!left)
            OutlinedButton(
              onPressed: () => Navigator.pop(context, 'group'),
              child: const Text('Участники и завершение участия'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Вернуться на карту'),
          ),
        ],
      ),
    ),
  );
}
