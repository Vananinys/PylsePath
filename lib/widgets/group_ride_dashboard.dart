import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../controllers/map_navigation_controller.dart';
import '../data/navigation_preferences.dart';
import '../models/group_coordination.dart';
import '../services/group_ride_service.dart';
import '../services/offline_maps_service.dart';
import '../screens/group_meeting_editor.dart';
import 'group_ride_actions.dart';
import 'shared_route_card.dart';

/// A map and one task at a time, rather than all room controls in one feed.
class GroupRideDashboard extends StatefulWidget {
  const GroupRideDashboard({
    super.key,
    required this.service,
    required this.busy,
    required this.onCreate,
    required this.onJoin,
    required this.onInvite,
    required this.onRoute,
    required this.onClearRoute,
    required this.onLeave,
    required this.onTransfer,
    required this.onReturn,
    this.navigation,
  });
  final GroupRideService service;
  final bool busy;
  final VoidCallback onCreate,
      onJoin,
      onInvite,
      onRoute,
      onClearRoute,
      onLeave,
      onTransfer,
      onReturn;
  final MapNavigationController? navigation;
  @override
  State<GroupRideDashboard> createState() => _GroupRideDashboardState();
}

class _GroupRideDashboardState extends State<GroupRideDashboard> {
  int _tab = 0;
  String? _room;
  LatLng? _focus;
  GroupRideService get service => widget.service;
  bool get busy => widget.busy || service.coordinating;
  bool get recording =>
      widget.navigation?.isWorkoutActive == true ||
      widget.navigation?.isWorkoutPaused == true;
  @override
  void initState() {
    super.initState();
    _room = service.activeRoomId;
    if (widget.navigation?.groupWorkoutConnected == true) _tab = 2;
  }

  @override
  void didUpdateWidget(GroupRideDashboard old) {
    super.didUpdateWidget(old);
    if (_room != service.activeRoomId) {
      _room = service.activeRoomId;
      _tab = widget.navigation?.groupWorkoutConnected == true ? 2 : 0;
      _focus = null;
    }
  }

  void _point(LatLng point) => setState(() => _focus = point);
  Future<void> _meeting() async {
    final scope = GroupActionScope(service);
    final result = await Navigator.push<GroupMeetPlan>(
      context,
      MaterialPageRoute(
        builder: (_) => GroupMeetingEditor(
          initial: service.coordination.plan,
          center: widget.navigation?.currentLocation,
        ),
      ),
    );
    if (mounted && result != null) {
      await scope.run(context, () => service.setMeeting(result));
    }
  }

  void _invite() => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheet) => SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Позовите своих', style: Theme.of(sheet).textTheme.titleLarge),
          const Text(
            'Друг открывает «Совместная поездка» и вводит код. Делитесь им только с участниками.',
          ),
          const SizedBox(height: 12),
          SelectableText(
            service.activeCode ?? 'Код загружается',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          TextButton.icon(
            onPressed: service.activeCode == null
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: service.activeCode!));
                    Navigator.pop(sheet);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Код группы скопирован')),
                    );
                  },
            icon: const Icon(Icons.copy),
            label: const Text('Скопировать код'),
          ),
          if (service.isHost)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(sheet);
                widget.onInvite();
              },
              icon: const Icon(Icons.chat_outlined),
              label: const Text('Пригласить через чат'),
            ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final inRoom = service.activeRoomId != null;
    final scope = GroupActionScope(service);
    final ready = service.members
        .where(
          (m) =>
              service.coordination.readiness[m.userId] == GroupReadiness.ready,
        )
        .length;
    final eventCount = service.coordination
        .activeSignals(DateTime.now())
        .length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Совместная поездка'),
        actions: [
          if (inRoom)
            IconButton(
              tooltip: 'Пригласить и показать код',
              onPressed: busy ? null : _invite,
              icon: const Icon(Icons.person_add_alt),
            ),
          PopupMenuButton<String>(
            tooltip: 'Настройки группы',
            onSelected: (value) {
              if (inRoom &&
                  (scope.room != service.activeRoomId ||
                      scope.owner != service.userId)) {
                return;
              }
              switch (value) {
                case 'refresh':
                  service.refreshMembers();
                case 'route':
                  widget.onRoute();
                case 'clear':
                  widget.onClearRoute();
                case 'transfer':
                  widget.onTransfer();
                case 'join':
                  widget.onJoin();
                case 'leave':
                  widget.onLeave();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'refresh', child: Text('Обновить')),
              if (inRoom && service.isHost) ...[
                const PopupMenuItem(
                  value: 'route',
                  child: Text('Выбрать маршрут'),
                ),
                if (service.route != null)
                  const PopupMenuItem(
                    value: 'clear',
                    child: Text('Убрать маршрут'),
                  ),
                if (service.members.any((m) => m.userId != service.userId))
                  const PopupMenuItem(
                    value: 'transfer',
                    child: Text('Передать управление'),
                  ),
              ],
              if (inRoom) ...[
                const PopupMenuItem(
                  value: 'join',
                  child: Text('В другую группу'),
                ),
                PopupMenuItem(
                  value: 'leave',
                  child: Text(
                    service.isHost ? 'Закрыть группу' : 'Выйти из группы',
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
      body: !inRoom
          ? _welcome(context)
          : SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.busy || service.refreshing)
                    const LinearProgressIndicator(),
                  if (service.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        service.error!,
                        maxLines: 3,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (service.notice != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(service.notice!, maxLines: 3),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          service.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${service.members.length} участников · готовы $ready${recording
                              ? widget.navigation?.groupWorkoutConnected == true
                                    ? ' · вы в групповом заезде'
                                    : ' · у вас отдельная запись'
                              : ' · собираемся'}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: _GroupRideMap(
                      key: ValueKey(service.activeRoomId),
                      service: service,
                      focus: _focus,
                      center: widget.navigation?.currentLocation,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Row(
                      children: [
                        for (final entry in [
                          (0, Icons.flag_outlined, 'Сбор'),
                          (1, Icons.people_outline, 'Люди'),
                          (2, Icons.directions_bike, 'В пути'),
                        ])
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                              ),
                              child: Badge(
                                isLabelVisible: entry.$1 == 2 && eventCount > 0,
                                label: Text('$eventCount'),
                                child: ChoiceChip(
                                  showCheckmark: false,
                                  label: Text(entry.$3, maxLines: 1),
                                  selected: _tab == entry.$1,
                                  onSelected: (_) =>
                                      setState(() => _tab = entry.$1),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                      child: switch (_tab) {
                        0 => _gather(context, ready),
                        1 => _people(context),
                        _ => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (service.coordination
                                .activeSignals(DateTime.now())
                                .isNotEmpty) ...[
                              GroupEventsCarousel(
                                service: service,
                                onPoint: _point,
                                disabled: busy,
                              ),
                              const SizedBox(height: 12),
                            ],
                            GroupRideActionPad(
                              service: service,
                              center: widget.navigation?.currentLocation,
                              disabled: busy,
                            ),
                            const SizedBox(height: 12),
                            if (service.coordination
                                .activeSignals(DateTime.now())
                                .isEmpty)
                              GroupEventsCarousel(
                                service: service,
                                onPoint: _point,
                                disabled: busy,
                              ),
                          ],
                        ),
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: FilledButton.icon(
                      onPressed: busy ? null : widget.onReturn,
                      icon: Icon(
                        recording ? Icons.map_outlined : Icons.arrow_forward,
                      ),
                      label: Text(
                        recording ? 'К своей поездке' : 'На главную — к старту',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _welcome(BuildContext context) => SafeArea(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.groups_2_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Сначала соберём своих',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            const Text(
              'Создай группу или войди по коду друга. Здесь договариваемся о встрече, а поездку начинаем на главном экране.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (service.error != null) Text(service.error!),
            FilledButton.icon(
              onPressed: busy || service.refreshing ? null : widget.onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Создать группу'),
            ),
            OutlinedButton.icon(
              onPressed: busy || service.refreshing ? null : widget.onJoin,
              icon: const Icon(Icons.key),
              label: const Text('Войти по коду'),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _gather(BuildContext context, int ready) {
    final plan = service.coordination.plan;
    final mine =
        service.coordination.readiness[service.userId] ??
        GroupReadiness.waiting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (service.members.length < 2)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Группа создана. Теперь позовите друзей.',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextButton.icon(
                    onPressed: busy ? null : _invite,
                    icon: const Icon(Icons.person_add),
                    label: const Text('Пригласить'),
                  ),
                ],
              ),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plan.point == null
                      ? 'Где встречаемся?'
                      : plan.label.isEmpty
                      ? 'Место сбора выбрано'
                      : plan.label,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (plan.startsAt != null)
                  Text(
                    '${plan.startsAt!.toLocal().day}.${plan.startsAt!.toLocal().month} · ${TimeOfDay.fromDateTime(plan.startsAt!.toLocal()).format(context)}',
                  ),
                Text(plan.style.label, style: const TextStyle(fontSize: 12)),
                Wrap(
                  spacing: 8,
                  children: [
                    if (plan.point != null)
                      TextButton.icon(
                        onPressed: () => _point(plan.point!),
                        icon: const Icon(Icons.place_outlined),
                        label: const Text('Показать'),
                      ),
                    if (service.isHost)
                      TextButton.icon(
                        onPressed: busy ? null : _meeting,
                        icon: const Icon(Icons.edit_location_alt_outlined),
                        label: Text(
                          plan.point == null
                              ? 'Выбрать место и время'
                              : 'Изменить сбор',
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Ваш ответ · ${mine.label}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final state in [
              GroupReadiness.going,
              GroupReadiness.late,
              GroupReadiness.ready,
            ])
              ChoiceChip(
                label: Text(state.label),
                selected: mine == state,
                onSelected: busy
                    ? null
                    : (_) =>
                          GroupActionScope(service)
                              .run(context, () => service.setReadiness(state)),
              ),
          ],
        ),
        Text(
          'Готовы $ready из ${service.members.length}. Остальные могут начать свою запись позже.',
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        if (service.route != null)
          Card(
            child: InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SharedRouteScreen(route: service.route!),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.route),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Маршрут группы · ${service.route!.title.isEmpty ? service.route!.label : service.route!.title}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ),
          )
        else if (service.isHost)
          TextButton.icon(
            onPressed: busy ? null : widget.onRoute,
            icon: const Icon(Icons.route_outlined),
            label: const Text('Добавить общий маршрут (необязательно)'),
          ),
        if (service.isHost)
          TextButton.icon(
            onPressed: busy
                ? null
                : () => sendGroupRideSignal(
                    context,
                    service,
                    GroupSignalKind.depart,
                  ),
            icon: const Icon(Icons.campaign_outlined),
            label: const Text('Позвать к старту'),
          ),
        const Text(
          'Дальше: главный экран → «Начать тренировку» → «В группе». Так каждый включает свою запись.',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  Widget _people(BuildContext context) => LayoutBuilder(
    builder: (context, limits) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final member in service.members)
          SizedBox(
            width: limits.maxWidth < 280
                ? limits.maxWidth
                : (limits.maxWidth - 8) / 2,
            child: Card(
              margin: EdgeInsets.zero,
              child: InkWell(
                onTap:
                    member.isLive &&
                        member.latitude != null &&
                        member.longitude != null
                    ? () => _point(LatLng(member.latitude!, member.longitude!))
                    : null,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      CircleAvatar(
                        child: Text(
                          member.username.isEmpty
                              ? '?'
                              : member.username.characters.first,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${member.username}${member.userId == service.userId ? ' · вы' : ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                      if (member.userId == service.hostId)
                        const Text(
                          'Организатор',
                          style: TextStyle(fontSize: 11),
                        ),
                      Text(
                        (service.coordination.readiness[member.userId] ??
                                GroupReadiness.waiting)
                            .label,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 12,
                        ),
                      ),
                      Text(switch (member.workoutState) {
                        'active' => 'В заезде',
                        'paused' => 'Пауза',
                        'finished' => 'Завершил',
                        _ => 'Ждёт старта',
                      }, style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (member.workoutState != 'waiting')
                        Text(
                          '${(member.distanceMeters / 1000).toStringAsFixed(1)} км · ${member.durationSeconds ~/ 60} мин',
                          style: const TextStyle(fontSize: 12),
                        ),
                      Text(
                        member.latitude == null
                            ? 'Позиция скрыта'
                            : member.isLive
                            ? 'Показать на карте'
                            : 'Позиция устарела',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _GroupRideMap extends StatefulWidget {
  const _GroupRideMap({
    super.key,
    required this.service,
    this.focus,
    this.center,
  });
  final GroupRideService service;
  final LatLng? focus, center;
  @override
  State<_GroupRideMap> createState() => _GroupRideMapState();
}

class _GroupRideMapState extends State<_GroupRideMap> {
  final _map = MapController();
  bool _ready = false;
  @override
  void didUpdateWidget(_GroupRideMap old) {
    super.didUpdateWidget(old);
    if (old.focus != widget.focus && widget.focus != null && _ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _map.move(widget.focus!, 16);
      });
    }
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final meeting = service.coordination.plan.point;
    final events = service.coordination
        .activeSignals(DateTime.now())
        .where((s) => s.point != null)
        .toList();
    final people = service.members
        .where((m) => m.isLive && m.latitude != null && m.longitude != null)
        .toList();
    final visible = [
      if (meeting != null) meeting,
      ...events.map((e) => e.point!),
      ...people.map((m) => LatLng(m.latitude!, m.longitude!)),
      ...service.route?.points ?? <LatLng>[],
    ];
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            onMapReady: () {
              if (mounted) setState(() => _ready = true);
            },
            initialCenter:
                visible.firstOrNull ??
                widget.center ??
                const LatLng(55.75, 37.62),
            initialZoom: 14,
            initialCameraFit: visible.length < 2
                ? null
                : CameraFit.bounds(
                    bounds: LatLngBounds.fromPoints(visible),
                    padding: const EdgeInsets.all(40),
                    maxZoom: 16,
                  ),
          ),
          children: [
            if (!NavigationPreferences.instance.cachedMapOnly ||
                OfflineMapsService.isAvailable)
              TileLayer(
                urlTemplate: OfflineMapsService.routeTileUrl,
                tileProvider: OfflineMapsService.tileProvider(
                  offlineOnly: NavigationPreferences.instance.cachedMapOnly,
                ),
                userAgentPackageName: 'com.pulsepath.app',
              ),
            if (service.route != null)
              PolylineLayer(
                polylines: [
                  for (final segment in service.route!.segments)
                    Polyline(
                      points: segment,
                      color: Colors.deepOrange,
                      strokeWidth: 4,
                    ),
                ],
              ),
            MarkerLayer(
              markers: [
                if (meeting != null)
                  Marker(
                    point: meeting,
                    width: 44,
                    height: 44,
                    child: const Tooltip(
                      message: 'Место сбора',
                      child: Icon(
                        Icons.flag_circle,
                        color: Colors.deepOrange,
                        size: 42,
                      ),
                    ),
                  ),
                for (final event in events)
                  Marker(
                    point: event.point!,
                    width: 44,
                    height: 44,
                    child: Tooltip(
                      message: event.note.isEmpty
                          ? event.kind.label
                          : event.note,
                      child: Icon(
                        event.kind == GroupSignalKind.stop
                            ? Icons.local_cafe
                            : Icons.campaign,
                        color: event.kind == GroupSignalKind.help
                            ? Colors.red
                            : Colors.teal,
                        size: 36,
                      ),
                    ),
                  ),
                for (final member in people)
                  Marker(
                    point: LatLng(member.latitude!, member.longitude!),
                    width: 36,
                    height: 36,
                    child: Tooltip(
                      message: member.username,
                      child: CircleAvatar(
                        backgroundColor: Colors.teal,
                        child: Text(
                          member.username.isEmpty
                              ? '?'
                              : member.username.characters.first,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution('© OpenStreetMap contributors'),
              ],
            ),
          ],
        ),
        Positioned(
          right: 8,
          top: 8,
          child: IconButton.filledTonal(
            tooltip: 'Показать всех',
            icon: const Icon(Icons.fit_screen),
            onPressed: !_ready || visible.isEmpty
                ? null
                : () {
                    if (visible.length == 1) {
                      _map.move(visible.first, 16);
                    } else {
                      _map.fitCamera(
                        CameraFit.bounds(
                          bounds: LatLngBounds.fromPoints(visible),
                          padding: const EdgeInsets.all(40),
                          maxZoom: 16,
                        ),
                      );
                    }
                  },
          ),
        ),
        if (visible.isEmpty)
          const Positioned(
            left: 8,
            right: 60,
            top: 8,
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'Место сбора пока не выбрано',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
