import 'package:flutter/material.dart';

import '../services/club_service.dart';
import 'section_intro.dart';

String clubDate(dynamic raw) {
  final date = DateTime.tryParse('$raw')?.toLocal();
  return date == null
      ? 'Время не указано'
      : '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')} · ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

class ClubOverview extends StatelessWidget {
  const ClubOverview({
    super.key,
    required this.data,
    required this.onChat,
    required this.onEvents,
    required this.onPeople,
    required this.onNotifications,
    required this.onRide,
    this.busy = false,
  });
  final Map<String, dynamic> data;
  final VoidCallback onChat, onEvents, onPeople, onNotifications, onRide;
  final bool busy;
  @override
  Widget build(BuildContext context) {
    final events =
        ClubService.rows(data['events'])
            .where(
              (e) =>
                  e['cancelled_at'] == null &&
                  (DateTime.tryParse('${e['starts_at']}')
                          ?.isAfter(DateTime.now()) ??
                      false),
            )
            .toList()
          ..sort((a, b) => '${a['starts_at']}'.compareTo('${b['starts_at']}'));
    final unread = (data['unread_count'] as num?)?.toInt() ?? 0;
    final people = ClubService.rows(data['members']);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionIntro(
          icon: Icons.diversity_3_outlined,
          eyebrow: 'ПОСТОЯННАЯ КОМАНДА',
          title: '${data['name']}',
          description:
              '${data['description'] ?? ''}\nКлуб объединяет людей. Каждый заезд создаётся отдельно, с новым приглашением и личным стартом.',
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: busy ? null : onRide,
          icon: const Icon(Icons.directions_bike),
          label: const Text('Пригласить клуб на заезд'),
        ),
        const SizedBox(height: 16),
        Text(
          'Ближайшее событие',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (events.isEmpty)
          Card(
            child: ListTile(
              leading: const Icon(Icons.event_available_outlined),
              title: const Text('Пока нет запланированных событий'),
              subtitle: const Text('Предложите встречу или совместный маршрут'),
              trailing: const Icon(Icons.chevron_right),
              onTap: onEvents,
            ),
          )
        else
          Card(
            child: ListTile(
              leading: const Icon(Icons.event_available_outlined),
              title: Text('${events.first['title']}'),
              subtitle: Text(
                '${clubDate(events.first['starts_at'])}\n${ClubService.rows(events.first['attendees']).length} планируют участвовать',
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: onEvents,
            ),
          ),
        Card(
          child: ListTile(
            leading: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.chat_bubble_outline),
            ),
            title: const Text('Чат клуба'),
            subtitle: Text(
              unread > 0
                  ? 'Новых сообщений: $unread'
                  : 'Обсуждения, вопросы и приглашения',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: onChat,
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.people_outline),
            title: Text('Участники · ${people.length}'),
            subtitle: const Text('Люди, роли и приглашения в клуб'),
            trailing: const Icon(Icons.chevron_right),
            onTap: onPeople,
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Уведомления клуба'),
            subtitle: Text(switch (data['notification_mode']) {
              'all' => 'Все сообщения и приглашения',
              'off' => 'Выключены',
              _ => 'Только приглашения на заезды и события',
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy ? null : onNotifications,
          ),
        ),
      ],
    );
  }
}
