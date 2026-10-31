import 'package:flutter/material.dart';

import '../services/group_ride_service.dart';
import 'section_intro.dart';

/// The everyday invitation flow; advanced coordination remains available separately.
class GroupWorkoutLobby extends StatelessWidget {
  const GroupWorkoutLobby({
    super.key,
    required this.service,
    required this.busy,
    required this.onInvite,
    required this.onPrepare,
    required this.onJoin,
    required this.onDetails,
    required this.onLeave,
    this.recording = false,
  });
  final GroupRideService service;
  final bool busy, recording;
  final VoidCallback onInvite, onPrepare, onJoin, onDetails, onLeave;
  @override
  Widget build(BuildContext context) {
    final joined = service.activeRoomId != null;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Совместная тренировка'),
        actions: [
          IconButton(
            onPressed: busy ? null : () => service.refreshMembers(),
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: service.refreshMembers,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            SectionIntro(
              icon: Icons.people_outline,
              eyebrow: 'ТРЕНИРОВКА С ДРУЗЬЯМИ',
              title: joined ? service.title : 'Пригласите и поезжайте вместе',
              description: 'Отправьте приглашение в чат. После принятия откроется обычная подготовка: каждый выберет свою активность и транспорт, затем нажмёт «Начать».',
            ),
            if (busy || service.refreshing) const LinearProgressIndicator(),
            if (service.error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  service.error!,
                  style: TextStyle(color: colors.error),
                ),
              ),
            if (service.notice != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(service.notice!),
              ),
            const SizedBox(height: 12),
            if (!joined) ...[
              FilledButton.icon(
                onPressed: busy ? null : onInvite,
                icon: const Icon(Icons.person_add_outlined),
                label: const Text('Пригласить друга'),
              ),
              const SizedBox(height: 12),
              const SectionStep(
                number: 1,
                title: 'Приглашение',
                description: 'Друг получит его в личном чате и уведомлении телефона, если уведомления разрешены.',
              ),
              const SectionStep(
                number: 2,
                title: 'Подготовка',
                description: 'Выберите велосипед, самокат, бег или прогулку — как в обычной тренировке.',
              ),
              const SectionStep(
                number: 3,
                title: 'Старт',
                description: 'Каждый запускает свою запись. Участники и прогресс остаются доступны в поездке.',
              ),
              TextButton(
                onPressed: busy ? null : onJoin,
                child: const Text('Есть код поездки? Войти по коду'),
              ),
            ] else ...[
              if (service.isHost)
                FilledButton.icon(
                  onPressed: busy ? null : onInvite,
                  icon: const Icon(Icons.person_add_outlined),
                  label: const Text('Пригласить ещё'),
                ),
              const SizedBox(height: 12),
              Text(
                'Участники · ${service.members.length}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final member in service.members)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Icon(
                        member.workoutState == 'recording'
                            ? Icons.directions_bike
                            : Icons.person_outline,
                      ),
                    ),
                    title: Text(
                      '${member.username}${member.userId == service.userId ? ' · вы' : ''}',
                    ),
                    subtitle: Text(switch (member.workoutState) {
                      'recording' => 'Записывает тренировку',
                      'paused' => 'Тренировка на паузе',
                      'finished' => 'Завершил тренировку',
                      _ => 'Настраивает тренировку',
                    }),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Если друг ещё не появился, он сможет принять приглашение в чате. Начать можно в удобный момент; запись у каждого своя.',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('Маршрут, место встречи и координация'),
                trailing: const Icon(Icons.chevron_right),
                onTap: onDetails,
              ),
              TextButton(
                onPressed: busy ? null : onLeave,
                child: Text(
                  service.isHost
                      ? 'Завершить совместную поездку'
                      : 'Выйти из совместной поездки',
                ),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: joined
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: busy ? null : onPrepare,
                  icon: Icon(recording ? Icons.map_outlined : Icons.tune),
                  label: Text(
                    recording
                        ? 'Вернуться к своей тренировке'
                        : 'Настроить тренировку',
                  ),
                ),
              ),
            )
          : null,
    );
  }
}
