import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/group_coordination.dart';
import '../services/group_ride_service.dart';
import '../screens/group_meeting_editor.dart';

class GroupActionScope {
  GroupActionScope(this.service)
    : room = service.activeRoomId,
      owner = service.userId,
      revision = service.membershipRevision;
  final GroupRideService service;
  final String? room, owner;
  final int revision;
  Future<bool> run(BuildContext context, Future<void> Function() action) async {
    try {
      if (room == null ||
          owner == null ||
          room != service.activeRoomId ||
          owner != service.userId ||
          revision != service.membershipRevision) {
        throw const GroupRideException(
          'Группа изменилась. Откройте её заново.',
        );
      }
      await action();
      return true;
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
      return false;
    }
  }
}

Future<void> proposeGroupStop(
  BuildContext context,
  GroupRideService service, {
  LatLng? center,
}) async {
  final scope = GroupActionScope(service);
  final replacesStop = service.coordination
      .activeSignals(DateTime.now())
      .any(
        (s) => s.authorId == service.userId && s.kind == GroupSignalKind.stop,
      );
  if (replacesStop) {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Заменить ваше предложение?'),
        content: const Text(
          'Новое сообщение заменит ваше предложение остановки. Ответы к прежнему предложению не перенесутся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Оставить предложение'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Заменить'),
          ),
        ],
      ),
    );
    if (!context.mounted || yes != true) return;
  }
  final plan = await Navigator.push<GroupMeetPlan>(
    context,
    MaterialPageRoute(
      builder: (_) => GroupMeetingEditor(
        initial: const GroupMeetPlan(),
        center: center,
        pointOnly: true,
        stopProposal: true,
      ),
    ),
  );
  if (!context.mounted || plan?.point == null) return;
  final sent = await scope.run(
    context,
    () => service.sendSignal(
      GroupSignalKind.stop,
      latitude: plan!.point!.latitude,
      longitude: plan.point!.longitude,
      note: plan.label,
    ),
  );
  if (sent && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Остановка предложена группе. Участники могут ответить «Я за».',
        ),
      ),
    );
  }
}

Future<void> sendGroupRideSignal(
  BuildContext context,
  GroupRideService service,
  GroupSignalKind kind,
) async {
  final scope = GroupActionScope(service);
  final replacing = service.coordination
      .activeSignals(DateTime.now())
      .any(
        (s) => s.authorId == service.userId && s.kind == GroupSignalKind.stop,
      );
  if (replacing &&
      kind != GroupSignalKind.help &&
      kind != GroupSignalKind.depart) {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Заменить предложение остановки?'),
        content: const Text(
          'Новое сообщение заменит ваше предложение и ответы к нему.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Заменить'),
          ),
        ],
      ),
    );
    if (!context.mounted || yes != true) return;
  }
  if (kind == GroupSignalKind.help || kind == GroupSignalKind.depart) {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
          kind == GroupSignalKind.help
              ? 'Сообщить, что нужна помощь?'
              : 'Позвать группу к старту?',
        ),
        content: Text(
          kind == GroupSignalKind.help
              ? 'Это сообщение участникам группы. Экстренные службы не вызываются.'
              : 'Участники увидят «Выезжаем». Каждый запускает свою запись на главном экране — чужие записи автоматически не включатся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Сообщить'),
          ),
        ],
      ),
    );
    if (!context.mounted || yes != true) return;
  }
  final sent = await scope.run(context, () => service.sendSignal(kind));
  if (sent && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Группе отправлено: ${kind.label}')));
  }
}

class GroupRideActionPad extends StatefulWidget {
  const GroupRideActionPad({
    super.key,
    required this.service,
    this.center,
    this.disabled = false,
  });
  final GroupRideService service;
  final LatLng? center;
  final bool disabled;
  @override
  State<GroupRideActionPad> createState() => _GroupRideActionPadState();
}

class _GroupRideActionPadState extends State<GroupRideActionPad> {
  bool _opening = false;
  Future<void> _run(Future<void> Function() action) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.disabled || widget.service.coordinating || _opening;
    Widget tile(IconData icon, String label, VoidCallback action) => SizedBox(
      width: (MediaQuery.sizeOf(context).width - 56) / 2,
      child: OutlinedButton(
        onPressed: busy ? null : action,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon),
            const SizedBox(height: 5),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            tile(
              Icons.add_location_alt_outlined,
              'Предложить остановку',
              () => _run(
                () => proposeGroupStop(
                  context,
                  widget.service,
                  center: widget.center,
                ),
              ),
            ),
            tile(
              Icons.front_hand_outlined,
              'Подождите меня',
              () => _run(
                () => sendGroupRideSignal(
                  context,
                  widget.service,
                  GroupSignalKind.wait,
                ),
              ),
            ),
            tile(
              Icons.thumb_up_alt_outlined,
              'Всё нормально',
              () => _run(
                () => sendGroupRideSignal(
                  context,
                  widget.service,
                  GroupSignalKind.okay,
                ),
              ),
            ),
            tile(
              Icons.support_outlined,
              'Нужна помощь',
              () => _run(
                () => sendGroupRideSignal(
                  context,
                  widget.service,
                  GroupSignalKind.help,
                ),
              ),
            ),
          ],
        ),
        TextButton(
          onPressed: busy
              ? null
              : () => _run(
                  () => sendGroupRideSignal(
                    context,
                    widget.service,
                    GroupSignalKind.stopped,
                  ),
                ),
          child: const Text('Я остановился'),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'Ответы и предложения обновляются, пока приложение открыто.',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class GroupEventsCarousel extends StatelessWidget {
  const GroupEventsCarousel({
    super.key,
    required this.service,
    required this.onPoint,
    this.disabled = false,
  });
  final GroupRideService service;
  final void Function(LatLng) onPoint;
  final bool disabled;
  @override
  Widget build(BuildContext context) {
    final events =
        List<GroupSignal>.of(service.coordination.activeSignals(DateTime.now()))
          ..sort((a, b) {
            final ah = a.kind == GroupSignalKind.help ? 0 : 1,
                bh = b.kind == GroupSignalKind.help ? 0 : 1;
            return ah == bh
                ? b.createdAt.compareTo(a.createdAt)
                : ah.compareTo(bh);
          });
    if (events.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Пока всё спокойно. Здесь появятся предложения остановиться и сообщения участников.',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${events.length} событий · листайте карточки вбок',
          style: const TextStyle(fontSize: 12),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final event in events)
                SizedBox(
                  width: (MediaQuery.sizeOf(context).width - 44).clamp(
                    220.0,
                    440.0,
                  ),
                  child: Card(
                    color: event.kind == GroupSignalKind.help
                        ? Theme.of(context).colorScheme.errorContainer
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${service.members.where((m) => m.userId == event.authorId).firstOrNull?.username ?? 'Участник'} · ${event.kind == GroupSignalKind.stop ? 'предлагает остановку' : event.kind.label}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          if (event.note.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(event.note),
                            ),
                          if (event.kind == GroupSignalKind.stop &&
                              event.authorId == service.userId)
                            const Text(
                              'Новое сообщение заменит это предложение.',
                              style: TextStyle(fontSize: 12),
                            ),
                          if (event.kind == GroupSignalKind.stop)
                            Text(
                              'Поддержали: ${event.responses.values.where((v) => v == 'coming').length}',
                            ),
                          Text(
                            'До ${TimeOfDay.fromDateTime(event.expiresAt.toLocal()).format(context)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          Wrap(
                            spacing: 6,
                            children: [
                              if (event.point != null)
                                TextButton.icon(
                                  onPressed: () => onPoint(event.point!),
                                  icon: const Icon(Icons.place_outlined),
                                  label: const Text('Место на карте'),
                                ),
                              if (event.authorId == service.userId)
                                TextButton(
                                  onPressed: disabled || service.coordinating
                                      ? null
                                      : () => GroupActionScope(service)
                                            .run(context, service.clearSignal),
                                  child: const Text('Снять'),
                                )
                              else ...[
                                TextButton(
                                  onPressed: disabled || service.coordinating
                                      ? null
                                      : () => GroupActionScope(service).run(
                                          context,
                                          () => service.respondToSignal(
                                            event.id,
                                            'coming',
                                          ),
                                        ),
                                  child: Text(
                                    '${event.responses[service.userId] == 'coming' ? '✓ ' : ''}${event.kind == GroupSignalKind.stop ? 'Я за' : 'Подъезжаю'}',
                                  ),
                                ),
                                TextButton(
                                  onPressed: disabled || service.coordinating
                                      ? null
                                      : () => GroupActionScope(service).run(
                                          context,
                                          () => service.respondToSignal(
                                            event.id,
                                            'seen',
                                          ),
                                        ),
                                  child: Text(
                                    event.responses[service.userId] == 'seen'
                                        ? '✓ Увидел'
                                        : 'Увидел',
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
