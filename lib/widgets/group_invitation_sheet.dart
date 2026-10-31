import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../models/friend_profile.dart';
import '../services/friend_service.dart';
import '../services/group_ride_service.dart';
import '../utils/ride_id.dart';
import '../config/app_variant.dart';
import '../services/group_workout_navigation.dart';

Future<bool> confirmGroupSwitch(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Перейти в другую комнату?'),
        content: const Text(
          'Вы покинете текущую комнату. Если вы организатор, она закроется для всех. Запись личной тренировки продолжится.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Остаться'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Перейти'),
          ),
        ],
      ),
    ) ??
    false;

/// Creating a room does not start a workout or send a message until confirmed.
Future<ChatMessage?> showGroupInvitationSheet(
  BuildContext context, {
  FriendProfile? friend,
}) async {
  final service = GroupRideService();
  try {
    await service.restoreSession();
    if (!context.mounted) return null;
    if (service.error != null) throw GroupRideException(service.error!);
    if (service.activeRoomId == null || !service.isHost) {
      if (service.activeRoomId != null && !await confirmGroupSwitch(context)) {
        return null;
      }
      if (!context.mounted) return null;
      if (AppVariant.uiBeta) {
        await service.createRoom(replace: service.activeRoomId != null);
      } else {
        final input = TextEditingController(text: 'Совместная тренировка');
        final title = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Создать совместный заезд'),
            content: TextField(
              controller: input,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, input.text.trim()),
                child: const Text('Создать'),
              ),
            ],
          ),
        );
        // The dialog's exit animation can still reference its controller.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        input.dispose();
        if (title == null || !context.mounted) return null;
        await service.createRoom(
          title: title,
          replace: service.activeRoomId != null,
        );
      }
    }
    if (!context.mounted) return null;
    return await showModalBottomSheet<ChatMessage>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          _InvitationSheet(friend: friend, roomId: service.activeRoomId!),
    );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
    return null;
  }
}

class _InvitationSheet extends StatefulWidget {
  const _InvitationSheet({required this.roomId, this.friend});
  final String roomId;
  final FriendProfile? friend;
  @override
  State<_InvitationSheet> createState() => _InvitationSheetState();
}

class _InvitationSheetState extends State<_InvitationSheet> {
  late Future<List<FriendProfile>> _friends = _load();
  final _ids = <String, String>{};
  final _sent = <String>{};
  final _service = GroupRideService();
  String? _sending, _error;
  Future<List<FriendProfile>> _load() async =>
      widget.friend == null ? FriendService().fetchFriends() : [widget.friend!];
  Future<void> _send(FriendProfile friend) async {
    setState(() {
      _sending = friend.id;
      _error = null;
    });
    try {
      if (_service.activeRoomId != widget.roomId || !_service.isHost) {
        throw const GroupRideException(
          'Комната изменилась. Откройте приглашение заново.',
        );
      }
      final row = await _service.sendInvitation(
        friend.id,
        _ids.putIfAbsent(friend.id, newRideId),
      );
      if (!mounted) return;
      final message = ChatMessage.fromRow(row);
      if (widget.friend != null) {
        Navigator.pop(context, message);
        if (AppVariant.uiBeta) _prepare();
        return;
      }
      setState(() => _sent.add(friend.id));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  void _prepare() {
    final room = _service.activeRoomId, owner = _service.userId;
    if (room != null && owner != null) {
      GroupWorkoutNavigation.instance.prepare(room: room, owner: owner);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _sending == null,
    child: SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: Column(
          children: [
            ListTile(
              title: const Text('Пригласить в заезд'),
              subtitle: Text(_service.title),
              trailing: IconButton(
                tooltip: 'Закрыть',
                onPressed: _sending == null
                    ? () => Navigator.pop(context)
                    : null,
                icon: const Icon(Icons.close),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Приглашение появится в чате и придёт уведомлением на телефон, если уведомления разрешены. После принятия друг выберет активность и транспорт. Приглашение действует 24 часа.',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: FutureBuilder<List<FriendProfile>>(
                future: _friends,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                      child: TextButton(
                        onPressed: () => setState(() => _friends = _load()),
                        child: const Text(
                          'Не удалось загрузить друзей. Повторить',
                        ),
                      ),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.data!.isEmpty) {
                    return const Center(
                      child: Text('Сначала добавьте друга в сообществе'),
                    );
                  }
                  return ListView(
                    children: [
                      for (final friend in snapshot.data!)
                        ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.person_outline),
                          ),
                          title: Text(friend.username),
                          subtitle: Text(
                            _sent.contains(friend.id)
                                ? 'Приглашение отправлено'
                                : 'Отправить в личный чат',
                          ),
                          trailing: _sending == friend.id
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(),
                                )
                              : Icon(
                                  _sent.contains(friend.id)
                                      ? Icons.check_circle
                                      : Icons.send,
                                ),
                          enabled:
                              _sending == null && !_sent.contains(friend.id),
                          onTap: () => _send(friend),
                        ),
                    ],
                  );
                },
              ),
            ),
            if (AppVariant.uiBeta && _sent.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: _sending == null
                      ? () {
                          Navigator.pop(context);
                          _prepare();
                        }
                      : null,
                  icon: const Icon(Icons.tune),
                  label: const Text('Настроить тренировку'),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
