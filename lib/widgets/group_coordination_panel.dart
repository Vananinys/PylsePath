import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/group_coordination.dart';
import '../services/group_ride_service.dart';
import '../screens/group_meeting_editor.dart';
import 'group_ride_actions.dart';

Future<void> _groupCommand(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is GroupRideException
                ? error.message
                : 'Действие не подтверждено. Обновите комнату и повторите.',
          ),
        ),
      );
    }
  }
}

class GroupCoordinationPanel extends StatelessWidget {
  const GroupCoordinationPanel({
    super.key,
    required this.service,
    this.disabled = false,
    this.center,
    this.onTransfer,
  });
  final GroupRideService service;
  final bool disabled;
  final LatLng? center;
  final Future<void> Function()? onTransfer;
  String _name(String id) =>
      service.members.where((m) => m.userId == id).firstOrNull?.username ??
      'Участник';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final room = service.activeRoomId, owner = service.userId;
      if (room == null || owner == null) return const SizedBox.shrink();
      final busy = disabled || service.coordinating;
      final data = service.coordination;
      Future<void> run(Future<void> Function() action) =>
          _groupCommand(context, () async {
            if (service.activeRoomId != room || service.userId != owner) {
              throw const GroupRideException('Комната или аккаунт изменились.');
            }
            await action();
          });
      Future<void> signal(GroupSignalKind kind) async {
        if (kind == GroupSignalKind.stop) {
          await proposeGroupStop(context, service, center: center);
          return;
        }
        if (kind == GroupSignalKind.help || kind == GroupSignalKind.depart) {
          final yes = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(kind.label),
              content: Text(
                kind == GroupSignalKind.help
                    ? 'Сообщение увидят участники при обновлении комнаты. Экстренные службы не вызываются.'
                    : 'Участники увидят сигнал к выезду. Каждый сам запускает свою запись.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Отправить'),
                ),
              ],
            ),
          );
          if (!context.mounted || yes != true) return;
        }
        await run(() => service.sendSignal(kind));
      }

      void showPoint(LatLng point, String label) => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GroupPointPreview(point: point, label: label),
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Text(
            'Готовность к выезду',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Text(
            'Это отметка участия. Запись тренировки включается отдельно.',
            style: TextStyle(fontSize: 12),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final state in GroupReadiness.values)
                ChoiceChip(
                  label: Text(state.label),
                  selected:
                      (data.readiness[owner] ?? GroupReadiness.waiting) ==
                      state,
                  onSelected: busy
                      ? null
                      : (_) => run(() => service.setReadiness(state)),
                ),
            ],
          ),
          Text(
            'Готовы: ${service.members.where((m) => data.readiness[m.userId] == GroupReadiness.ready).length} из ${service.members.length}',
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    data.plan.label.isEmpty
                        ? 'Место сбора пока не задано'
                        : data.plan.label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(data.plan.style.label),
                  if (data.plan.startsAt != null)
                    Text('Сбор: ${_date(context, data.plan.startsAt!)}'),
                  if (data.plan.departedAt != null)
                    Text(
                      'Выезд объявлен: ${_date(context, data.plan.departedAt!)}',
                    ),
                  if (data.plan.point != null)
                    TextButton.icon(
                      onPressed: () =>
                          showPoint(data.plan.point!, 'Точка сбора'),
                      icon: const Icon(Icons.place),
                      label: const Text('Показать место сбора'),
                    ),
                  if (service.isHost)
                    TextButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              final plan = await Navigator.push<GroupMeetPlan>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => GroupMeetingEditor(
                                    initial: data.plan,
                                    center: center,
                                  ),
                                ),
                              );
                              if (context.mounted && plan != null) {
                                await run(() => service.setMeeting(plan));
                              }
                            },
                      icon: const Icon(Icons.edit_location_alt),
                      label: const Text('Место, время и темп'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Команды группе',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final kind in GroupSignalKind.values)
                if (kind != GroupSignalKind.depart || service.isHost)
                  OutlinedButton(
                    onPressed: busy ? null : () => signal(kind),
                    child: Text(kind.label),
                  ),
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        final kind =
                            await showModalBottomSheet<GroupSignalKind>(
                              context: context,
                              useSafeArea: true,
                              builder: (sheet) => Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (final kind in GroupSignalKind.values)
                                    if (kind != GroupSignalKind.depart ||
                                        service.isHost)
                                      ListTile(
                                        title: Text(kind.label),
                                        onTap: () => Navigator.pop(sheet, kind),
                                      ),
                                ],
                              ),
                            );
                        if (!context.mounted || kind == null) return;
                        final plan = await Navigator.push<GroupMeetPlan>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => GroupMeetingEditor(
                              initial: const GroupMeetPlan(),
                              center: center,
                              pointOnly: true,
                            ),
                          ),
                        );
                        if (context.mounted && plan?.point != null) {
                          await run(
                            () => service.sendSignal(
                              kind,
                              latitude: plan!.point!.latitude,
                              longitude: plan.point!.longitude,
                            ),
                          );
                        }
                      },
                icon: const Icon(Icons.add_location_alt),
                label: const Text('Команда с выбранным местом'),
              ),
            ],
          ),
          const Text(
            'Обновляются при открытом приложении. Нет сети — нет подтверждения доставки.',
            style: TextStyle(fontSize: 12),
          ),
          for (final event in data.activeSignals(DateTime.now()))
            Card(
              color: event.kind == GroupSignalKind.help
                  ? Theme.of(context).colorScheme.errorContainer
                  : null,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${_name(event.authorId)}: ${event.kind.label}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      'До ${TimeOfDay.fromDateTime(event.expiresAt.toLocal()).format(context)} · ответили ${event.responses.length}',
                    ),
                    if (event.responses.isNotEmpty)
                      Text(
                        event.responses.entries
                            .map(
                              (e) =>
                                  '${_name(e.key)}: ${e.value == 'coming' ? 'подъезжаю' : 'увидел'}',
                            )
                            .join(', '),
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (event.point != null)
                          TextButton(
                            onPressed: () =>
                                showPoint(event.point!, event.kind.label),
                            child: const Text('Место команды'),
                          ),
                        if (event.authorId == owner)
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => run(service.clearSignal),
                            child: const Text('Снять команду'),
                          ),
                        if (event.authorId != owner) ...[
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => run(
                                    () => service.respondToSignal(
                                      event.id,
                                      'seen',
                                    ),
                                  ),
                            child: Text(
                              event.responses[owner] == 'seen'
                                  ? '✓ Увидел'
                                  : 'Увидел',
                            ),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => run(
                                    () => service.respondToSignal(
                                      event.id,
                                      'coming',
                                    ),
                                  ),
                            child: Text(
                              event.responses[owner] == 'coming'
                                  ? '✓ Подъезжаю'
                                  : 'Подъезжаю',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (service.isHost && onTransfer != null)
            TextButton.icon(
              onPressed: busy ? null : onTransfer,
              icon: const Icon(Icons.manage_accounts_outlined),
              label: const Text('Передать управление'),
            ),
        ],
      );
    },
  );
  String _date(BuildContext context, DateTime value) {
    final local = value.toLocal();
    return '${local.day}.${local.month}.${local.year} · ${TimeOfDay.fromDateTime(local).format(context)}';
  }
}

class GroupRideQuickActions extends StatelessWidget {
  const GroupRideQuickActions({
    super.key,
    required this.service,
    required this.onOpen,
    this.disabled = false,
    this.workoutRoomId,
    this.legacyLayout = false,
  });
  final GroupRideService service;
  final VoidCallback onOpen;
  final bool disabled;
  final String? workoutRoomId;
  final bool legacyLayout;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      if (!legacyLayout) {
        if (workoutRoomId == null) return const SizedBox.shrink();
        if (workoutRoomId != service.activeRoomId) {
          return Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              service.refreshing ? 'Обновляем связь с группой…' : 'Связь с прежней группой завершена. Ваша личная запись продолжается.',
              textAlign: TextAlign.center,
            ),
          );
        }
        final active =
            service.coordination
                .activeSignals(DateTime.now())
                .where((e) => e.authorId != service.userId)
                .toList()
              ..sort((a, b) {
                if (a.kind == GroupSignalKind.help &&
                    b.kind != GroupSignalKind.help) {
                  return -1;
                }
                if (b.kind == GroupSignalKind.help &&
                    a.kind != GroupSignalKind.help) {
                  return 1;
                }
                return b.createdAt.compareTo(a.createdAt);
              });
        final latest = active.firstOrNull;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (latest != null)
              TextButton.icon(
                onPressed: disabled ? null : onOpen,
                icon: Icon(
                  latest.kind == GroupSignalKind.help
                      ? Icons.support_outlined
                      : Icons.campaign_outlined,
                ),
                label: Text(
                  latest.kind == GroupSignalKind.stop
                      ? 'Предлагают остановку · ${latest.note.isEmpty ? 'посмотреть' : latest.note}'
                      : latest.kind.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: disabled ? null : onOpen,
                  icon: const Icon(Icons.groups_outlined),
                  label: Text('Группа · ${service.members.length}'),
                ),
                TextButton.icon(
                  onPressed: disabled || service.coordinating
                      ? null
                      : () => proposeGroupStop(context, service),
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: const Text('Остановка'),
                ),
              ],
            ),
          ],
        );
      }
      if (service.activeRoomId == null) return const SizedBox.shrink();
      final busy = disabled || service.coordinating;
      final events = service.coordination.activeSignals(DateTime.now());
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (events.any(
            (e) =>
                e.kind == GroupSignalKind.help && e.authorId != service.userId,
          ))
            const Text(
              'Участник сообщил, что нужна помощь',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          Wrap(
            spacing: 6,
            alignment: WrapAlignment.center,
            children: [
              TextButton.icon(
                onPressed: disabled ? null : onOpen,
                icon: const Icon(Icons.groups),
                label: Text(
                  'Группа · ${service.members.length} · команд ${events.length}',
                ),
              ),
              PopupMenuButton<GroupSignalKind>(
                enabled: !busy,
                tooltip: 'Команда группе',
                icon: const Icon(Icons.campaign_outlined),
                itemBuilder: (_) => [
                  for (final kind in GroupSignalKind.values.where(
                    (k) => k != GroupSignalKind.depart,
                  ))
                    PopupMenuItem(value: kind, child: Text(kind.label)),
                ],
                onSelected: (kind) async {
                  final room = service.activeRoomId, owner = service.userId;
                  if (kind == GroupSignalKind.help) {
                    final yes = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Сообщить группе о помощи?'),
                        content: const Text(
                          'Участники увидят команду при обновлении. Экстренные службы не вызываются.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Отмена'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Сообщить'),
                          ),
                        ],
                      ),
                    );
                    if (!context.mounted || yes != true) return;
                  }
                  await _groupCommand(context, () async {
                    if (room != service.activeRoomId ||
                        owner != service.userId) {
                      throw const GroupRideException(
                        'Комната или аккаунт изменились.',
                      );
                    }
                    await service.sendSignal(kind);
                  });
                },
              ),
            ],
          ),
        ],
      );
    },
  );
}
