import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../models/shared_route.dart';
import '../services/group_ride_service.dart';
import '../screens/group_ride_screen.dart';
import 'group_invitation_sheet.dart';
import 'shared_route_card.dart';
import '../config/app_variant.dart';
import '../services/group_workout_navigation.dart';

Future<void> showGroupInvitationDetails(BuildContext context, String id) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => GroupInvitationDetails(id: id),
    );

class GroupInvitationCard extends StatelessWidget {
  const GroupInvitationCard({super.key, required this.message});
  final ChatMessage message;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 280,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.groups_2, color: Colors.deepOrange, size: 32),
        const Text(
          'Совместный заезд',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        Text(message.groupInvitation?['title']?.toString() ?? 'Приглашение'),
        Text(
          'Организатор: ${message.groupInvitation?['organizer'] ?? 'Райдер'}',
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: message.delivery == MessageDelivery.sent
              ? () => showGroupInvitationDetails(context, message.id)
              : null,
          icon: const Icon(Icons.login),
          label: const Text('Открыть приглашение'),
        ),
      ],
    ),
  );
}

class GroupInvitationDetails extends StatefulWidget {
  const GroupInvitationDetails({super.key, required this.id, this.service});
  final String id;
  final GroupRideService? service;
  @override
  State<GroupInvitationDetails> createState() => _InviteDetailsState();
}

class _InviteDetailsState extends State<GroupInvitationDetails>
    with WidgetsBindingObserver {
  late final _service = widget.service ?? GroupRideService();
  Map<String, dynamic>? _data;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _load();
  }

  Future<void> _load({String action = 'view', bool replace = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await _service.invitation(
        widget.id,
        action: action,
        replace: replace,
      );
      if (mounted) setState(() => _data = data);
      if (mounted &&
          AppVariant.uiBeta &&
          action == 'accept' &&
          data['status'] == 'joined') {
        _prepare();
      }
    } on GroupRideException catch (error) {
      if (!mounted) return;
      if (error.replaceRequired && await confirmGroupSwitch(context)) {
        if (!mounted) return;
        setState(() => _busy = false);
        await _load(action: action, replace: true);
        return;
      }
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Не удалось проверить приглашение. Повторите.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _prepare() {
    final room = _service.activeRoomId, owner = _service.userId;
    if (room == null ||
        owner == null ||
        _service.error != null ||
        _service.coordinating) {
      setState(
        () => _error =
            'Не удалось загрузить поездку. Обновите приглашение и повторите.',
      );
      return;
    }
    Navigator.pop(context);
    GroupWorkoutNavigation.instance.prepare(room: room, owner: owner);
  }

  @override
  Widget build(BuildContext context) {
    final state = _data?['status'];
    final isSender =
        _data != null &&
        _service.userId != null &&
        _data?['sender_id'] == _service.userId;
    final route = SharedRoute.tryParse(_data?['route_attachment']);
    final label = switch (state) {
      'active' => 'Приглашение активно',
      'joined' => isSender ? 'Вы организатор' : 'Вы уже в этой комнате',
      'closed' => 'Комната закрыта',
      'revoked' => 'Приглашение отозвано',
      'expired' => 'Срок приглашения истёк',
      'blocked' => 'Переписка недоступна',
      'unavailable' => 'Приглашение удалено или недоступно',
      _ => 'Проверяем приглашение…',
    };
    return PopScope(
      canPop: !_busy,
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _data?['title']?.toString() ?? 'Совместный заезд',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                Text(label),
                if (_data?['members_count'] != null)
                  Text('Участников: ${_data!['members_count']}'),
                if (_data?['expires_at'] != null)
                  Text(
                    'Действует до ${DateTime.tryParse(_data!['expires_at'].toString())?.toLocal().toString().split('.').first ?? '—'}',
                  ),
                if (route != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: SharedRouteCard(route: route),
                  ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    'После принятия выберите активность и транспорт в обычной подготовке. Запись начнётся только по вашей кнопке. Геопозиция передаётся согласно вашим настройкам.',
                  ),
                ),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (state == 'active' && !isSender)
                  FilledButton(
                    onPressed: _busy ? null : () => _load(action: 'accept'),
                    child: const Text('Принять и настроить тренировку'),
                  ),
                if (state == 'joined')
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            if (AppVariant.uiBeta) {
                              await _service.restoreSession();
                              if (mounted) _prepare();
                              return;
                            }
                            final navigator = Navigator.of(context);
                            navigator.pop();
                            await navigator.push(
                              MaterialPageRoute<void>(
                                builder: (_) => const GroupRideScreen(),
                              ),
                            );
                          },
                    child: const Text('Открыть комнату'),
                  ),
                if (isSender && state != 'revoked' && state != 'closed')
                  TextButton(
                    onPressed: _busy ? null : () => _load(action: 'revoke'),
                    child: const Text('Отозвать приглашение'),
                  ),
                TextButton(
                  onPressed: _busy ? null : () => _load(),
                  child: const Text('Обновить состояние'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
