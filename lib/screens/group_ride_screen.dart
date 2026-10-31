import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../controllers/map_navigation_controller.dart';
import '../services/group_ride_service.dart';
import '../widgets/group_invitation_sheet.dart';
import '../widgets/route_share_sheet.dart';
import '../widgets/shared_route_card.dart';
import '../widgets/group_coordination_panel.dart';
import '../models/group_coordination.dart';
import '../widgets/group_ride_dashboard.dart';
import '../widgets/group_workout_lobby.dart';
import '../services/group_workout_navigation.dart';
import '../config/app_variant.dart';

class GroupRideScreen extends StatefulWidget {
  const GroupRideScreen({
    super.key,
    this.navigationController,
    this.service,
    this.legacyLayout = false,
    this.advanced = false,
  });
  final MapNavigationController? navigationController;
  final GroupRideService? service;
  final bool legacyLayout;
  final bool advanced;
  @override
  State<GroupRideScreen> createState() => _GroupRideScreenState();
}

class _GroupRideScreenState extends State<GroupRideScreen>
    with WidgetsBindingObserver {
  late final _service = widget.service ?? GroupRideService();
  bool _busy = false;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service.addListener(_changed);
    unawaited(_service.restoreSession());
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(_service.refreshMembers());
      }
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_service.restoreSession());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _service.removeListener(_changed);
    super.dispose();
  }

  Future<void> _run(Future<void> Function(bool replace) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action(false);
    } on GroupRideException catch (error) {
      if (!mounted) return;
      if (error.replaceRequired && await confirmGroupSwitch(context)) {
        try {
          await action(true);
        } catch (cause) {
          _error(cause);
        }
      } else {
        _error(error);
      }
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _error(Object error) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<bool> _join() async {
    final input = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Войти по коду'),
        content: TextField(
          controller: input,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          maxLength: 12,
          decoration: const InputDecoration(labelText: '12 символов кода'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, input.text),
            child: const Text('Войти'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (code == null || !mounted) return false;
    bool joined = false;
    await _run((replace) async {
      await _service.joinRoom(code, replace: replace);
      joined = true;
    });
    return joined;
  }

  Future<void> _leave() async {
    final room = _service.activeRoomId;
    if (room == null) return;
    if (_service.uiFlow) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Завершить участие в заезде?'),
          content: const Text(
            'Личная запись продолжится, если она ещё идёт. Остальные останутся в заезде; управление перейдёт участнику. Для следующего заезда понадобится новое приглашение.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Остаться'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Завершить участие'),
            ),
          ],
        ),
      );
      if (yes == true && mounted)
        await _run((_) => _service.endParticipation());
      return;
    }
    if (_service.isHost &&
        _service.members.any((m) => m.userId != _service.userId)) {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Выйти из совместного заезда?'),
          content: const Text(
            'Можно передать управление участнику и сохранить комнату. Личная запись продолжится.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'close'),
              child: const Text('Закрыть для всех'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'transfer'),
              child: const Text('Передать и выйти'),
            ),
          ],
        ),
      );
      if (!mounted || action == null) return;
      if (action == 'transfer') {
        await _transferHost(leaveAfter: true);
        return;
      }
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_service.isHost ? 'Закрыть комнату?' : 'Выйти из комнаты?'),
        content: Text(
          _service.isHost
              ? 'Все участники покинут комнату. Их личные записи тренировки продолжатся.'
              : 'Ваша личная тренировка продолжится.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Подтвердить'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run((_) => _service.leaveRoom(room, isHost: _service.isHost));
    }
  }

  Future<void> _transferHost({bool leaveAfter = false}) async {
    final room = _service.activeRoomId, owner = _service.userId;
    final members = _service.members.where((m) => m.userId != owner).toList();
    if (room == null || !_service.isHost || members.isEmpty) {
      _error(
        const GroupRideException('Нужен другой участник текущей комнаты.'),
      );
      return;
    }
    final selected = await showModalBottomSheet<GroupMember>(
      context: context,
      useSafeArea: true,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Новый организатор'),
          ),
          for (final member in members)
            ListTile(
              title: Text(member.username),
              onTap: () => Navigator.pop(sheet, member),
            ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Передать управление: ${selected.username}?'),
        content: Text(
          'Новый организатор сможет менять маршрут и сбор. Старые непринятые приглашения будут отозваны.'
          '${leaveAfter ? ' Вы выйдете из комнаты, личная запись продолжится.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Передать'),
          ),
        ],
      ),
    );
    if (!mounted || yes != true) return;
    await _run((_) async {
      if (_service.activeRoomId != room ||
          _service.userId != owner ||
          !_service.isHost) {
        throw const GroupRideException(
          'Комната или организатор изменились. Обновите экран.',
        );
      }
      await _service.transferHost(selected.userId);
      if (leaveAfter) await _service.leaveRoom(room, isHost: false);
    });
  }

  Future<void> _createGroup() async {
    final input = TextEditingController(text: 'Наша поездка');
    final title = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Как назовём группу?'),
        content: TextField(
          controller: input,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Название группы'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, input.text.trim()),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (!mounted || title == null) return;
    await _run(
      (replace) => _service.createRoom(
        title: title.isEmpty ? 'Наша поездка' : title,
        replace: replace,
      ),
    );
  }

  Future<void> _chooseRoute() async {
    final room = _service.activeRoomId, owner = _service.userId;
    final route = await showLocalRoutePicker(context);
    if (!mounted || route == null) return;
    await _run((_) async {
      if (room != _service.activeRoomId || owner != _service.userId) {
        throw const GroupRideException(
          'Группа изменилась. Откройте её заново.',
        );
      }
      await _service.setRoute(route);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (AppVariant.uiBeta && !widget.legacyLayout && !widget.advanced) {
      return GroupWorkoutLobby(
        service: _service,
        busy: _busy,
        recording:
            widget.navigationController?.isWorkoutActive == true ||
            widget.navigationController?.isWorkoutPaused == true,
        onInvite: () => showGroupInvitationSheet(context),
        onJoin: () async {
          if (await _join() && mounted) _prepare();
        },
        onPrepare: _prepare,
        onNewRide: () async {
          final yes = await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
              title: const Text('Новый заезд?'),
              content: const Text(
                'Вы завершите участие в прежнем заезде и создадите новый. Друзья смогут присоединиться только после принятия новых приглашений.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('Создать новый заезд'),
                ),
              ],
            ),
          );
          if (yes == true && mounted)
            await _run((_) => _service.newRide(replace: true));
        },
        onDetails: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GroupRideScreen(
              service: _service,
              navigationController: widget.navigationController,
              advanced: true,
            ),
          ),
        ),
        onLeave: _leave,
      );
    }
    if (!widget.legacyLayout) {
      return GroupRideDashboard(
        service: _service,
        busy: _busy,
        navigation: widget.navigationController,
        onCreate: _createGroup,
        onJoin: _join,
        onInvite: () => showGroupInvitationSheet(context),
        onRoute: _chooseRoute,
        onClearRoute: () => _run((_) => _service.setRoute(null)),
        onLeave: _leave,
        onTransfer: () => _transferHost(),
        onReturn: () {
          if (AppVariant.uiBeta) {
            _prepare();
            return;
          }
          if (widget.navigationController == null) {
            Navigator.popUntil(context, (route) => route.isFirst);
            return;
          }
          Navigator.pop(
            context,
            widget.navigationController!.isWorkoutActive ||
                    widget.navigationController!.isWorkoutPaused
                ? 'map'
                : 'prepare_group',
          );
        },
      );
    }
    final inRoom = _service.activeRoomId != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Совместный заезд'),
        actions: [
          IconButton(
            onPressed: _busy || _service.refreshing
                ? null
                : () => _service.refreshMembers(),
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _service.refreshMembers,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          children: [
            if (_service.refreshing || _busy) const LinearProgressIndicator(),
            if (_service.error != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_service.error!),
                ),
              ),
            if (_service.notice != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_service.notice!),
              ),
            if (!inRoom) ...[
              const SizedBox(height: 40),
              const Icon(Icons.groups_2, size: 76, color: Colors.deepOrange),
              const SizedBox(height: 16),
              Text(
                'Катайте вместе',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Создайте комнату и пригласите друзей в чате. В комнате видны прогресс и разрешённые участниками позиции.',
                  textAlign: TextAlign.center,
                ),
              ),
              FilledButton.icon(
                onPressed: _busy || _service.refreshing
                    ? null
                    : () => _run((replace) async {
                        await _service.createRoom(replace: replace);
                      }),
                icon: const Icon(Icons.add),
                label: const Text('Создать комнату'),
              ),
              OutlinedButton.icon(
                onPressed: _busy || _service.refreshing ? null : _join,
                icon: const Icon(Icons.login),
                label: const Text('Войти по коду'),
              ),
            ] else ...[
              Text(
                _service.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                _service.realtimeConnected
                    ? 'Обновления в реальном времени подключены'
                    : 'Проверяем данные каждые 15 секунд',
              ),
              if (_service.lastSyncedAt != null)
                Text(
                  'Проверено в ${TimeOfDay.fromDateTime(_service.lastSyncedAt!).format(context)}',
                ),
              Card(
                child: ListTile(
                  title: Text(
                    _service.activeCode!,
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                  subtitle: const Text(
                    'Код даёт доступ к комнате. Делитесь им только с участниками.',
                  ),
                  trailing: IconButton(
                    tooltip: 'Скопировать код',
                    icon: const Icon(Icons.copy),
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: _service.activeCode!),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Код скопирован')),
                      );
                    },
                  ),
                ),
              ),
              if (_service.isHost) ...[
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => showGroupInvitationSheet(context),
                  icon: const Icon(Icons.person_add),
                  label: const Text('Пригласить друзей в чат'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          final route = await showLocalRoutePicker(context);
                          if (route != null && mounted) {
                            await _run((_) => _service.setRoute(route));
                          }
                        },
                  icon: const Icon(Icons.route),
                  label: Text(
                    _service.route == null
                        ? 'Добавить маршрут группы'
                        : 'Изменить маршрут группы',
                  ),
                ),
              ],
              if (_service.route != null) ...[
                SharedRouteCard(route: _service.route!),
                const Text(
                  'Общий маршрут можно открыть на карте. Запись тренировки запускает каждый участник.',
                ),
                if (_service.isHost)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run((_) => _service.setRoute(null)),
                    child: const Text('Убрать маршрут'),
                  ),
              ],
              const SizedBox(height: 16),
              Text(
                'Участники (${_service.members.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              GroupCoordinationPanel(
                service: _service,
                disabled: _busy,
                center: widget.navigationController?.currentLocation,
                onTransfer: () => _transferHost(),
              ),
              for (final member in _service.members) _member(member),
              const SizedBox(height: 12),
              if (widget.navigationController != null)
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => Navigator.pop(context, 'start'),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(
                    widget.navigationController!.isWorkoutActive
                        ? 'Вернуться к тренировке'
                        : 'Начать свою тренировку',
                  ),
                )
              else
                const Text(
                  'Чтобы начать личную запись, вернитесь на карту и нажмите «Начать тренировку».',
                ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Позиция передаётся согласно настройкам геопозиции. Зелёная метка означает свежие данные, а не подтверждённое движение.',
                ),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _join,
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Перейти в другую комнату'),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _leave,
                icon: const Icon(Icons.exit_to_app),
                label: Text(
                  _service.isHost ? 'Закрыть комнату' : 'Выйти из комнаты',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _prepare() {
    final room = _service.activeRoomId, owner = _service.userId;
    if (room != null && owner != null) {
      GroupWorkoutNavigation.instance.prepare(room: room, owner: owner);
    }
  }

  Widget _member(GroupMember member) {
    final state = switch (member.workoutState) {
      'active' => 'В заезде',
      'paused' => 'На паузе',
      'finished' => 'Завершил',
      _ => 'Ждёт старта',
    };
    final me = member.userId == _service.userId;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: member.isLive ? Colors.teal : Colors.grey,
          backgroundImage: member.avatarUrl?.startsWith('https://') == true
              ? NetworkImage(member.avatarUrl!)
              : null,
          child: member.avatarUrl?.startsWith('https://') == true
              ? null
              : const Icon(Icons.person, color: Colors.white),
        ),
        title: Text(
          '${member.username}${me ? ' (вы)' : ''}${member.userId == _service.hostId ? ' · организатор' : ''}',
        ),
        subtitle: Text(
          '${(_service.coordination.readiness[member.userId] ?? GroupReadiness.waiting).label} · $state · ${(member.distanceMeters / 1000).toStringAsFixed(2)} км · ${member.durationSeconds ~/ 60} мин\nДанные: ${member.ageText}${member.isLive ? '' : ' · связь давно не обновлялась'}${member.latitude == null ? '\nПозиция сейчас не передаётся' : ''}',
        ),
        isThreeLine: true,
        trailing: member.latitude != null
            ? const Icon(Icons.location_on_outlined)
            : null,
        onTap: member.latitude == null || member.longitude == null
            ? null
            : () => Navigator.pop(
                context,
                LatLng(member.latitude!, member.longitude!),
              ),
      ),
    );
  }
}
