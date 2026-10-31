import 'package:flutter/material.dart';

import '../models/group_coordination.dart';
import '../services/group_ride_service.dart';
import 'group_invitation_card.dart';

String participantStage(GroupMember member, GroupRideService service) =>
    switch (member.workoutState) {
      'active' || 'recording' => 'Начал тренировку',
      'paused' => 'На паузе',
      'finished' => 'Завершил тренировку',
      _ =>
        service.coordination.readiness[member.userId] == GroupReadiness.ready
            ? 'Готов к старту'
            : 'Принял · настраивает тренировку',
    };

class GroupJourneyPanel extends StatelessWidget {
  const GroupJourneyPanel({
    super.key,
    required this.service,
    this.busy = false,
  });
  final GroupRideService service;
  final bool busy;
  Future<void> _cancel(
    BuildContext context,
    Map<String, dynamic> invite,
  ) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Отменить приглашение?'),
        content: Text(
          'Получатель: ${invite['username']}. После отмены он не сможет принять это приглашение.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Назад'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Отменить приглашение'),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    try {
      await service.invitation('${invite['id']}', action: 'revoke');
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (service.invitations.isNotEmpty) ...[
        Text('Приглашения', style: Theme.of(context).textTheme.titleMedium),
        for (final invite in service.invitations)
          Card(
            child: ListTile(
              leading: Icon(
                invite['status'] == 'pending'
                    ? Icons.hourglass_top
                    : invite['status'] == 'accepted'
                    ? Icons.check_circle_outline
                    : Icons.mail_outline,
              ),
              title: Text('${invite['username']}'),
              subtitle: Text(switch (invite['status']) {
                'pending' =>
                  invite['receiver_id'] == service.userId
                      ? 'Приглашает: ${invite['title']}'
                      : 'Приглашён · ожидаем ответа',
                'accepted' => 'Принял приглашение',
                'declined' => 'Отказался от приглашения',
                'revoked' => 'Приглашение отменено',
                'expired' => 'Срок истёк',
                _ => 'Поездка завершена',
              }),
              onTap: busy
                  ? null
                  : () => showGroupInvitationDetails(
                      context,
                      '${invite['id']}',
                      service: service,
                    ),
              trailing:
                  invite['status'] == 'pending' &&
                      invite['sender_id'] == service.userId
                  ? IconButton(
                      onPressed: busy ? null : () => _cancel(context, invite),
                      tooltip: 'Отменить приглашение',
                      icon: const Icon(Icons.close),
                    )
                  : const Icon(Icons.chevron_right),
            ),
          ),
      ],
      if (service.activeRoomId != null) ...[
        Text(
          'Участники · ${service.members.length}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        for (final member in service.members)
          Card(
            child: ListTile(
              leading: CircleAvatar(
                child: Icon(
                  member.workoutState == 'active' ||
                          member.workoutState == 'recording'
                      ? Icons.directions_bike
                      : Icons.person_outline,
                ),
              ),
              title: Text(
                '${member.username}${member.userId == service.userId ? ' · вы' : ''}',
              ),
              subtitle: Text(
                '${participantStage(member, service)}${const ['active','recording','paused','finished'].contains(member.workoutState) ? '\n${(member.distanceMeters / 1000).toStringAsFixed(2)} км · ${Duration(seconds: member.durationSeconds).inMinutes} мин' : ''}${!member.isLive ? '\nДанные ${member.ageText}' : ''}',
              ),
            ),
          ),
      ],
    ],
  );
}
