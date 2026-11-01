import 'package:flutter/material.dart';

class EventOverviewCard extends StatelessWidget {
  const EventOverviewCard({
    super.key,
    required this.event,
    required this.busy,
    required this.onJoin,
    required this.onFeedback,
    required this.onClaim,
    this.onResults,
    this.onArchive,
  });
  final Map<String, dynamic> event;
  final bool busy;
  final VoidCallback onJoin, onFeedback, onClaim;
  final VoidCallback? onResults, onArchive;

  static bool ended(Map<String, dynamic> event) {
    final end = DateTime.tryParse('${event['ends_at']}');
    return end != null && !end.isAfter(DateTime.now());
  }

  static bool scheduled(Map<String, dynamic> event) =>
      DateTime.tryParse('${event['starts_at']}')?.isAfter(DateTime.now()) ==
      true;
  static String date(Object? raw) {
    final value = DateTime.tryParse('$raw')?.toLocal();
    if (value == null) return 'Срок не указан';
    return '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year} · ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final challenge = event['kind'] == 'challenge';
    final survey = event['metric'] == 'feedback' || event['kind'] == 'beta';
    final joined = event['joined'] == true, earned = event['earned'] == true;
    final closed = ended(event), upcoming = scheduled(event);
    final canAct =
        !closed &&
        !upcoming &&
        DateTime.tryParse('${event['ends_at']}') != null;
    final status = earned
        ? 'Награда получена'
        : closed
        ? 'Завершено'
        : upcoming
        ? 'Скоро начнётся'
        : joined
        ? 'Вы участвуете'
        : 'Можно участвовать';
    final next = earned
        ? 'Опыт уже начислен. Повторно получать награду не нужно.'
        : closed
        ? 'Срок участия и получения награды закончился.'
        : upcoming
        ? 'Участие откроется ${date(event['starts_at'])}.'
        : !joined
        ? 'Вступите, чтобы начать выполнение условий.'
        : survey
        ? 'Заполните опрос, затем получите награду.'
        : 'Сохраните и синхронизируйте тренировки после вступления, затем проверьте результат.';
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.secondaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(
                      challenge
                          ? Icons.emoji_events_outlined
                          : survey
                          ? Icons.rate_review_outlined
                          : Icons.event_outlined,
                      color: colors.onSecondaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        challenge
                            ? 'ЧЕЛЛЕНДЖ'
                            : survey
                            ? 'ОПРОС'
                            : 'СОБЫТИЕ',
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${event['title'] ?? 'Событие'}',
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                if (onResults != null || onArchive != null)
                  PopupMenuButton<String>(
                    tooltip: 'Управление событием',
                    enabled: !busy,
                    onSelected: (value) => value == 'results'
                        ? onResults?.call()
                        : onArchive?.call(),
                    itemBuilder: (_) => [
                      if (onResults != null)
                        const PopupMenuItem(
                          value: 'results',
                          child: Text('Ответы'),
                        ),
                      if (onArchive != null)
                        const PopupMenuItem(
                          value: 'archive',
                          child: Text('Завершить'),
                        ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                Chip(
                  avatar: Icon(
                    earned ? Icons.check_circle_outline : Icons.schedule,
                    size: 18,
                  ),
                  label: Text(status),
                ),
                Chip(
                  avatar: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: Text('${event['xp'] ?? 0} XP'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '${event['description'] ?? ''}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            Text(
              'До ${date(event['ends_at'])}',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            if ('${event['badge'] ?? ''}'.isNotEmpty)
              Text(
                'Награда: ${event['badge']}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const Divider(),
            if (challenge)
              Text(
                'Цель: ${event['target'] ?? '—'} ${switch (event['metric']) {
                  'distance_km' => 'км',
                  'minutes' => 'минут',
                  _ => 'тренировок',
                }} после вступления.',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            Text(next, style: Theme.of(context).textTheme.bodyMedium),
            if (canAct && !earned) ...[
              const SizedBox(height: 16),
              if (!joined)
                FilledButton.icon(
                  onPressed: busy ? null : onJoin,
                  icon: const Icon(Icons.add),
                  label: const Text('Участвовать'),
                )
              else if (survey) ...[
                FilledButton.icon(
                  onPressed: busy ? null : onFeedback,
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Пройти опрос'),
                ),
                TextButton.icon(
                  onPressed: busy ? null : onClaim,
                  icon: const Icon(Icons.workspace_premium_outlined),
                  label: const Text('Получить награду'),
                ),
              ] else
                FilledButton.icon(
                  onPressed: busy ? null : onClaim,
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Проверить прогресс'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
