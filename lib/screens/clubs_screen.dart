import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/club_service.dart';
import '../services/push_service.dart';
import '../services/chat_service.dart';
import '../services/friend_service.dart';
import '../services/group_ride_service.dart';
import '../services/group_workout_navigation.dart';
import '../utils/ride_id.dart';
import '../widgets/group_invitation_sheet.dart';
import '../widgets/section_intro.dart';
import '../widgets/club_overview.dart';

String _role(dynamic role) => switch (role) {
  'owner' => 'Организатор',
  'admin' => 'Администратор',
  _ => 'Участник',
};
String _date(dynamic raw) {
  final d = DateTime.tryParse('$raw')?.toLocal();
  return d == null
      ? 'Время не указано'
      : '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year} · ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class ClubsScreen extends StatefulWidget {
  const ClubsScreen({super.key, this.service});
  final ClubService? service;
  @override
  State<ClubsScreen> createState() => _ClubsScreenState();
}

class _ClubsScreenState extends State<ClubsScreen> {
  Timer? refreshTimer;
  late final service = widget.service ?? ClubService();
  List<Map<String, dynamic>>? clubs;
  String? error;
  bool loading = false, mine = true;
  bool creating = false;
  Map<String, dynamic>? pendingClub;
  String query = '';
  @override
  void initState() {
    super.initState();
    _load();
    refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted &&
          !creating &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          ModalRoute.of(context)?.isCurrent == true)
        _load(background: true);
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool background = false}) async {
    if (loading) return;
    if (background) {
      loading = true;
    } else {
      setState(() => loading = true);
    }
    try {
      final result = await service.home();
      if (mounted)
        setState(() {
          clubs = result;
          error = null;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          error = e.toString();
          if (e is ClubException && e.accessLost) clubs = null;
        });
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _open(String id) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ClubDetailScreen(id: id, service: service),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _create() async {
    if (creating) return;
    final data = await _clubEditor(context, initial: pendingClub);
    if (data == null || !mounted) return;
    pendingClub = {...data, 'id': pendingClub?['id'] ?? newRideId()};
    setState(() => creating = true);
    try {
      final row = await service.action('create', data: pendingClub!);
      pendingClub = null;
      if (mounted) await _open('${row['id']}');
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => creating = false);
    }
  }

  Future<void> _joinCode() async {
    final code = await _textDialog(
      context,
      'Приглашение в клуб',
      'Код из приглашения',
      maxLength: 32,
    );
    if (code == null || !mounted) return;
    try {
      final row = await service.action('join_code', data: {'code': code});
      if (mounted) await _open('${row['id']}');
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = (clubs ?? [])
        .where(
          (c) =>
              (mine ? c['member'] == true : true) &&
              '${c['name']} ${c['description']}'.toLowerCase().contains(
                query.toLowerCase(),
              ),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Клубы')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            const SectionIntro(
              icon: Icons.diversity_3_outlined,
              eyebrow: 'ВАШЕ СООБЩЕСТВО',
              title: 'Свои люди. Общие планы.',
              description: 'Соберите постоянную команду: общайтесь, планируйте события и приглашайте участников на тренировки.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: loading || creating ? null : _create,
                  icon: const Icon(Icons.add),
                  label: const Text('Создать клуб'),
                ),
                OutlinedButton.icon(
                  onPressed: loading || creating ? null : _joinCode,
                  icon: const Icon(Icons.key_outlined),
                  label: const Text('По приглашению'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Мои клубы')),
                ButtonSegment(value: false, label: Text('Найти клуб')),
              ],
              selected: {mine},
              onSelectionChanged: (s) => setState(() => mine = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              onChanged: (s) => setState(() => query = s),
              decoration: const InputDecoration(
                labelText: 'Поиск по названию',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            if (loading) const LinearProgressIndicator(),
            if (error != null) _errorCard(context, error!, _load),
            if (clubs != null && visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Text(
                  mine
                      ? 'Вы пока не вступили в клуб. Найдите открытый или создайте свой.'
                      : 'Подходящих открытых клубов нет. Закрытые доступны по приглашению.',
                  textAlign: TextAlign.center,
                ),
              ),
            for (final c in visible)
              Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  leading: CircleAvatar(
                    child: Icon(
                      c['is_open'] == true
                          ? Icons.groups_outlined
                          : Icons.lock_outline,
                    ),
                  ),
                  title: Text('${c['name']}'),
                  subtitle: Text(
                    '${c['members_count']} участников · ${c['member'] == true ? _role(c['role']) : 'Открытый клуб'}${(c['unread_count'] as num? ?? 0) > 0 ? ' · ${c['unread_count']} новых' : ''}\n${c['description']}',
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open('${c['id']}'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ClubDetailScreen extends StatefulWidget {
  const ClubDetailScreen({
    super.key,
    required this.id,
    required this.service,
    this.initialTab = 0,
  });
  final String id;
  final ClubService service;
  final int initialTab;
  @override
  State<ClubDetailScreen> createState() => _ClubDetailScreenState();
}

class _ClubDetailScreenState extends State<ClubDetailScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Map<String, dynamic>? data;
  String? error;
  bool loading = false, busy = false;
  int revision = 0;
  late final tabs = TabController(
    length: 4,
    vsync: this,
    initialIndex: widget.initialTab,
  )..addListener(_tabChanged);
  bool markingRead = false;
  void _tabChanged() {
    if (tabs.index == 1 && !tabs.indexIsChanging) _markRead();
  }

  Future<void> _markRead() async {
    if (markingRead || !member || busy) return;
    markingRead = true;
    final owner = service.userId;
    try {
      await service.action('read', club: widget.id);
      if (mounted && owner == service.userId)
        setState(() => data?['unread_count'] = 0);
      if (mounted && owner == service.userId)
        unawaited(PushService.instance.clearClubNotification(widget.id));
    } catch (_) {
    } finally {
      markingRead = false;
    }
  }

  Future<void> _notifications() async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text('Уведомления этого клуба'),
            subtitle: Text(
              'Дополнительно разрешите уведомления в настройках телефона.',
            ),
          ),
          for (final option in {
            'all': 'Все сообщения и приглашения',
            'invitations': 'Только приглашения на заезды и события',
            'off': 'Выключены',
          }.entries)
            ListTile(
              leading: Icon(
                data?['notification_mode'] == option.key
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              title: Text(option.value),
              onTap: () => Navigator.pop(sheet, option.key),
            ),
        ],
      ),
    );
    if (mode != null) await _run('notifications', payload: {'mode': mode});
  }

  Timer? timer;
  final input = TextEditingController();
  final chatScroll = ScrollController();
  String? pendingMessageId;
  String? pendingMessageBody;
  Map<String, dynamic>? pendingEvent;
  String? pendingRideRoom, pendingRideMessage;
  List<Map<String, dynamic>> older = [];
  bool historyEnd = false;
  ClubService get service => widget.service;
  bool get member => data?['member'] == true;
  bool get admin => data?['role'] == 'owner' || data?['role'] == 'admin';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    tabs;
    _load();
    timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed)
        _load();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    tabs.dispose();
    WidgetsBinding.instance.removeObserver(this);
    input.dispose();
    chatScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    if (loading || busy) return;
    loading = true;
    final request = revision;
    final follow =
        !chatScroll.hasClients || chatScroll.position.extentAfter < 120;
    try {
      final row = await service.snapshot(widget.id);
      if (mounted && request == revision)
        setState(() {
          data = row;
          error = null;
        });
      if (mounted && request == revision && follow) _scrollChat();
      if (mounted && tabs.index == 1 && (row['unread_count'] as num? ?? 0) > 0)
        unawaited(_markRead());
    } catch (e) {
      if (mounted && request == revision) _handleError(e);
    } finally {
      loading = false;
    }
  }

  Future<bool> _run(
    String action, {
    Map<String, dynamic> payload = const {},
  }) async {
    if (busy) return false;
    revision++;
    setState(() => busy = true);
    try {
      final row = await service.action(action, club: widget.id, data: payload);
      if (!mounted) return false;
      if (action == 'leave') {
        Navigator.pop(context);
        return true;
      }
      setState(() {
        data = Map<String, dynamic>.from(row as Map);
        error = null;
      });
      if (action == 'message') _scrollChat();
      return true;
    } catch (e) {
      if (mounted) _handleError(e);
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _scrollChat() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && chatScroll.hasClients)
        chatScroll.jumpTo(chatScroll.position.maxScrollExtent);
    });
  }

  void _handleError(Object e) {
    setState(() {
      error = '$e';
      if (e is ClubException && e.accessLost) {
        data = null;
        older = [];
        input.clear();
        pendingEvent = null;
        pendingRideRoom = null;
        pendingRideMessage = null;
      }
    });
  }

  Future<void> _send() async {
    final body = input.text.trim();
    if (body.isEmpty) return;
    if (pendingMessageBody != body) {
      pendingMessageId = newRideId();
      pendingMessageBody = body;
    }
    if (await _run(
      'message',
      payload: {'id': pendingMessageId, 'body': body},
    )) {
      if (input.text.trim() == body) input.clear();
      pendingMessageId = null;
      pendingMessageBody = null;
    }
  }

  Future<void> _older() async {
    if (busy) return;
    setState(() => busy = true);
    final oldExtent = chatScroll.hasClients
        ? chatScroll.position.maxScrollExtent
        : 0.0;
    final oldOffset = chatScroll.hasClients ? chatScroll.offset : 0.0;
    try {
      final current = [...older, ...ClubService.rows(data?['messages'])];
      final rows = ClubService.rows(
        await service.action(
          'messages',
          club: widget.id,
          data: {if (current.isNotEmpty) 'before': current.first['created_at']},
        ),
      );
      if (mounted)
        setState(() {
          older = [...rows, ...older];
          historyEnd = rows.length < 50;
        });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && chatScroll.hasClients)
          chatScroll.jumpTo(
            (oldOffset + chatScroll.position.maxScrollExtent - oldExtent).clamp(
              0,
              chatScroll.position.maxScrollExtent,
            ),
          );
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _edit() async {
    final changed = await _clubEditor(context, initial: data);
    if (changed != null) await _run('update', payload: changed);
  }

  Future<void> _invite() async {
    final code = '${data?['invite_code']}';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Пригласить в «${data?['name']}»',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Код даёт вход в клуб. Делитесь им только с теми, кого хотите пригласить.',
            ),
            SelectableText(code),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                if (sheet.mounted)
                  ScaffoldMessenger.of(sheet).showSnackBar(
                    const SnackBar(content: Text('Код скопирован')),
                  );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Скопировать код'),
            ),
            FilledButton.icon(
              onPressed: () async {
                Navigator.pop(sheet);
                await _inviteFriend(code);
              },
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Отправить другу в чат'),
            ),
            if (data?['role'] == 'owner')
              TextButton(
                onPressed: () async {
                  Navigator.pop(sheet);
                  if (await _confirm(
                    'Обновить приглашение?',
                    'Прежний код перестанет работать. Участники останутся в клубе.',
                  ))
                    await _run('rotate_code');
                },
                child: const Text('Обновить код приглашения'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _inviteFriend(String code) async {
    try {
      final friends = await FriendService().fetchFriends();
      if (!mounted) return;
      final friend = await showModalBottomSheet<String>(
        context: context,
        useSafeArea: true,
        builder: (sheet) => ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Кому отправить приглашение?')),
            if (friends.isEmpty)
              const ListTile(
                title: Text('Сначала добавьте друга в сообществе'),
              ),
            for (final f in friends)
              ListTile(
                title: Text(f.username),
                trailing: const Icon(Icons.send_outlined),
                onTap: () => Navigator.pop(sheet, f.id),
              ),
          ],
        ),
      );
      if (friend == null || !mounted) return;
      setState(() => busy = true);
      final sent = await ChatService().sendMessage(
        friend,
        text:
            'Приглашаю в клуб «${data?['name']}»!\nКод: $code\nОткройте меню → Клубы → По приглашению и вставьте код.',
        messageId: newRideId(),
      );
      if (sent == null)
        throw const ClubException('Приглашение не отправлено. Повторите.');
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Приглашение отправлено в чат')),
        );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _confirm(String title, String description) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: Text(description),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Подтвердить'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _ride({
    Map<String, dynamic>? invite,
    Map<String, dynamic>? event,
  }) async {
    if (busy) return;
    final group = GroupRideService();
    if (!await _confirm(
      invite == null
          ? 'Пригласить клуб на тренировку?'
          : invite['sender_id'] == service.userId
          ? 'Открыть подготовку тренировки?'
          : 'Принять приглашение на тренировку?',
      invite == null
          ? 'В клубном чате появится приглашение. Затем вы выберете свою активность и транспорт.'
          : 'Откроется обычная подготовка: активность, транспорт и настройки. Запись запускается вашей кнопкой.',
    ))
      return;
    if (!mounted) return;
    setState(() => busy = true);
    revision++;
    final owner = service.userId;
    try {
      await group.restoreSession();
      if (owner == null || owner != service.userId || owner != group.userId)
        throw const ClubException('Аккаунт изменился.');
      if (group.error != null) throw ClubException(group.error!);
      if (invite == null) {
        if (group.activeRoomId == null || !group.isHost || group.ownFinished) {
          final replace = group.activeRoomId != null;
          if (replace && (!mounted || !await confirmGroupSwitch(context)))
            return;
          if (!mounted) return;
          await group.createRoom(
            title:
                event?['title']?.toString() ?? '${data?['name']} · тренировка',
            replace: replace,
          );
        }
        if (pendingRideRoom != group.activeRoomId ||
            pendingRideMessage == null) {
          pendingRideRoom = group.activeRoomId;
          pendingRideMessage = newRideId();
        }
        final invitedRoom = group.activeRoomId;
        final participantsBefore = group.members.map((m) => m.userId).toList();
        final shared = await service.action(
          'share_ride',
          club: widget.id,
          data: {'id': pendingRideMessage, 'room_id': group.activeRoomId},
        );
        if (mounted)
          setState(() => data = Map<String, dynamic>.from(shared as Map));
        pendingRideMessage = null;
        group.waitForNewParticipant(
          room: invitedRoom,
          existing: participantsBefore,
        );
        if (mounted) {
          tabs.animateTo(1);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Приглашение отправлено в чат клуба. Ожидаем, пока участник сам его примет.',
              ),
            ),
          );
        }
        await group.refreshMembers();
        return;
      } else {
        bool replace = false;
        if (group.activeRoomId != null &&
            group.activeRoomId != invite['ride_id']) {
          if (!mounted || !await confirmGroupSwitch(context)) return;
          replace = true;
        }
        await service.action(
          'join_ride',
          club: widget.id,
          data: {'id': invite['id'], 'replace': replace},
        );
        await group.restoreSession();
        if (group.error != null || group.activeRoomId != invite['ride_id'])
          throw const ClubException(
            'Не удалось загрузить поездку. Обновите клуб и повторите.',
          );
      }
      if (mounted && owner == service.userId && group.activeRoomId != null)
        GroupWorkoutNavigation.instance.prepare(
          room: group.activeRoomId!,
          owner: owner,
        );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _event() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ClubEventEditor(initial: pendingEvent),
    );
    if (result != null) {
      pendingEvent = result;
      if (await _run('event_create', payload: result)) pendingEvent = null;
    }
  }

  Future<void> _memberAction(Map<String, dynamic> person, String action) async {
    if (!await _confirm(switch (action) {
      'transfer' => 'Передать управление клубом?',
      'remove' => 'Исключить участника?',
      _ => 'Изменить роль участника?',
    }, 'Участник: ${person['username'] ?? 'Райдер'}. История чата сохранится.'))
      return;
    await _run(
      action == 'admin' || action == 'member' ? 'role' : action,
      payload: {'user_id': person['user_id'], 'role': action},
    );
  }

  @override
  Widget build(BuildContext context) {
    final people = ClubService.rows(data?['members']);
    final messages = <String, Map<String, dynamic>>{
      for (final m in [...older, ...ClubService.rows(data?['messages'])])
        '${m['id']}': m,
    }.values.toList();
    final events = ClubService.rows(data?['events']);
    int eventOrder(Map<String, dynamic> e) => e['cancelled_at'] != null
        ? 2
        : (DateTime.tryParse('${e['starts_at']}')?.isBefore(DateTime.now()) ??
              true)
        ? 1
        : 0;
    events.sort((a, b) {
      final status = eventOrder(a).compareTo(eventOrder(b));
      return status != 0
          ? status
          : '${a['starts_at']}'.compareTo('${b['starts_at']}');
    });
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(data?['name']?.toString() ?? 'Клуб'),
          actions: [
            if (admin)
              IconButton(
                onPressed: busy ? null : _invite,
                tooltip: 'Пригласить в клуб',
                icon: const Icon(Icons.person_add_outlined),
              ),
            IconButton(
              onPressed: busy ? null : _load,
              tooltip: 'Обновить',
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: member
              ? TabBar(
                  controller: tabs,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: const [
                    Tab(text: 'Главная'),
                    Tab(text: 'Чат'),
                    Tab(text: 'События'),
                    Tab(text: 'Участники'),
                  ],
                )
              : null,
        ),
        body: data == null
            ? Column(
                children: [
                  if (error != null) _errorCard(context, error!, _load),
                  if (error == null) const LinearProgressIndicator(),
                ],
              )
            : Column(
                children: [
                  if (busy) const LinearProgressIndicator(),
                  if (error != null) _errorCard(context, error!, _load),
                  if (!member)
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          Text('${data?['description']}'),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: busy ? null : () => _run('join'),
                            child: const Text('Вступить в клуб'),
                          ),
                        ],
                      ),
                    )
                  else
                    Expanded(
                      child: TabBarView(
                        controller: tabs,
                        children: [
                          ClubOverview(
                            data: data!,
                            busy: busy,
                            onChat: () => tabs.animateTo(1),
                            onEvents: () => tabs.animateTo(2),
                            onPeople: () => tabs.animateTo(3),
                            onNotifications: _notifications,
                            onRide: () => _ride(),
                          ),
                          Column(
                            children: [
                              Expanded(
                                child: ListView(
                                  controller: chatScroll,
                                  padding: const EdgeInsets.all(12),
                                  children: [
                                    if (!historyEnd &&
                                        (messages.length >= 50 ||
                                            older.isNotEmpty))
                                      TextButton(
                                        onPressed: busy ? null : _older,
                                        child: const Text(
                                          'Загрузить предыдущие сообщения',
                                        ),
                                      ),
                                    if (messages.isEmpty)
                                      const Padding(
                                        padding: EdgeInsets.all(24),
                                        child: Text(
                                          'Здесь начинается общение клуба. Напишите первое сообщение или пригласите участников на тренировку.',
                                        ),
                                      ),
                                    for (final m in messages)
                                      Card(
                                        color: m['sender_id'] == service.userId
                                            ? Theme.of(context)
                                                  .colorScheme
                                                  .primaryContainer
                                            : null,
                                        child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${m['username'] ?? 'Райдер'} · ${_date(m['created_at'])}',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall,
                                              ),
                                              const SizedBox(height: 6),
                                              SelectableText('${m['body']}'),
                                              if (m['ride_id'] != null)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 8,
                                                      ),
                                                  child: FilledButton.icon(
                                                    onPressed:
                                                        busy ||
                                                            m['ride_open'] !=
                                                                true
                                                        ? null
                                                        : () =>
                                                              _ride(invite: m),
                                                    icon: const Icon(
                                                      Icons.tune,
                                                    ),
                                                    label: Text(
                                                      m['ride_open'] == true
                                                          ? m['sender_id'] ==
                                                                    service
                                                                        .userId
                                                                ? 'Настроить тренировку'
                                                                : 'Принять и настроить тренировку'
                                                          : 'Поездка завершена',
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              SafeArea(
                                top: false,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      OutlinedButton.icon(
                                        onPressed: busy ? null : () => _ride(),
                                        icon: const Icon(Icons.directions_bike),
                                        label: const Text(
                                          'Пригласить на тренировку',
                                        ),
                                      ),
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Expanded(
                                            child: TextField(
                                              controller: input,
                                              minLines: 1,
                                              maxLines: 4,
                                              maxLength: 2000,
                                              decoration: const InputDecoration(
                                                hintText: 'Сообщение клубу',
                                                counterText: '',
                                              ),
                                            ),
                                          ),
                                          IconButton(
                                            onPressed: busy ? null : _send,
                                            tooltip: 'Отправить',
                                            icon: const Icon(Icons.send),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              FilledButton.icon(
                                onPressed: busy ? null : _event,
                                icon: const Icon(
                                  Icons.event_available_outlined,
                                ),
                                label: const Text('Создать событие'),
                              ),
                              if (events.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text(
                                    'Запланируйте встречу, прогулку или совместный заезд. Участники смогут отметить, что придут.',
                                  ),
                                ),
                              for (final e in events)
                                Builder(
                                  builder: (context) {
                                    final attendees = ClubService.rows(
                                      e['attendees'],
                                    );
                                    final ended =
                                        DateTime.tryParse('${e['starts_at']}')
                                            ?.isBefore(DateTime.now()) ??
                                        true;
                                    final cancelled = e['cancelled_at'] != null;
                                    return Card(
                                      child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Text(
                                              '${e['title']}',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium,
                                            ),
                                            Text(_date(e['starts_at'])),
                                            if (cancelled)
                                              const Text('Событие отменено')
                                            else if (ended)
                                              const Text(
                                                'Время события наступило',
                                              ),
                                            const SizedBox(height: 8),
                                            Text('${e['description']}'),
                                            ExpansionTile(
                                              tilePadding: EdgeInsets.zero,
                                              title: Text(
                                                'Планируют участвовать · ${attendees.length}',
                                              ),
                                              children: [
                                                for (final a in attendees)
                                                  ListTile(
                                                    title: Text(
                                                      '${a['username'] ?? 'Райдер'}',
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            if (!cancelled && !ended)
                                              OutlinedButton(
                                                onPressed: busy
                                                    ? null
                                                    : () => _run(
                                                        'event_attend',
                                                        payload: {
                                                          'id': e['id'],
                                                          'attending':
                                                              e['attending'] !=
                                                              true,
                                                        },
                                                      ),
                                                child: Text(
                                                  e['attending'] == true
                                                      ? 'Я участвую · отменить'
                                                      : 'Буду участвовать',
                                                ),
                                              ),
                                            if (!cancelled)
                                              TextButton.icon(
                                                onPressed: busy
                                                    ? null
                                                    : () => _ride(event: e),
                                                icon: const Icon(
                                                  Icons.directions_bike,
                                                ),
                                                label: const Text(
                                                  'Пригласить клуб на тренировку',
                                                ),
                                              ),
                                            if (!cancelled &&
                                                (admin ||
                                                    e['author_id'] ==
                                                        service.userId))
                                              TextButton(
                                                onPressed: busy
                                                    ? null
                                                    : () async {
                                                        if (await _confirm(
                                                          'Отменить событие?',
                                                          'Событие останется в истории с отметкой об отмене.',
                                                        ))
                                                          await _run(
                                                            'event_cancel',
                                                            payload: {
                                                              'id': e['id'],
                                                            },
                                                          );
                                                      },
                                                child: const Text(
                                                  'Отменить событие',
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                            ],
                          ),
                          ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              Text('${data?['description']}'),
                              const SizedBox(height: 8),
                              Text(
                                data?['is_open'] == true
                                    ? 'Открытый клуб'
                                    : 'Закрытый клуб · вход по приглашению',
                              ),
                              if (admin)
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    TextButton.icon(
                                      onPressed: busy ? null : _edit,
                                      icon: const Icon(Icons.edit_outlined),
                                      label: const Text('Изменить клуб'),
                                    ),
                                    TextButton.icon(
                                      onPressed: busy ? null : _invite,
                                      icon: const Icon(
                                        Icons.person_add_outlined,
                                      ),
                                      label: const Text('Пригласить'),
                                    ),
                                  ],
                                ),
                              for (final p in people)
                                ListTile(
                                  leading: const CircleAvatar(
                                    child: Icon(Icons.person_outline),
                                  ),
                                  title: Text(
                                    '${p['username'] ?? 'Райдер'}${p['user_id'] == service.userId ? ' · вы' : ''}',
                                  ),
                                  subtitle: Text(_role(p['role'])),
                                  trailing:
                                      admin &&
                                          p['user_id'] != service.userId &&
                                          p['role'] != 'owner'
                                      ? PopupMenuButton<String>(
                                          enabled: !busy,
                                          onSelected: (a) =>
                                              _memberAction(p, a),
                                          itemBuilder: (_) => [
                                            if (data?['role'] == 'owner')
                                              PopupMenuItem(
                                                value: p['role'] == 'admin'
                                                    ? 'member'
                                                    : 'admin',
                                                child: Text(
                                                  p['role'] == 'admin'
                                                      ? 'Сделать участником'
                                                      : 'Назначить администратором',
                                                ),
                                              ),
                                            if (data?['role'] == 'owner')
                                              const PopupMenuItem(
                                                value: 'transfer',
                                                child: Text(
                                                  'Передать управление',
                                                ),
                                              ),
                                            if (data?['role'] == 'owner' ||
                                                p['role'] != 'admin')
                                              const PopupMenuItem(
                                                value: 'remove',
                                                child: Text(
                                                  'Исключить из клуба',
                                                ),
                                              ),
                                          ],
                                        )
                                      : null,
                                ),
                              const SizedBox(height: 20),
                              if (data?['role'] == 'owner')
                                const Text(
                                  'Чтобы выйти, сначала передайте управление участнику через меню справа от его имени.',
                                )
                              else
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () async {
                                          if (await _confirm(
                                            'Выйти из клуба?',
                                            'Чат закрытого клуба станет недоступен. Сообщения сохранятся у участников.',
                                          ))
                                            await _run('leave');
                                        },
                                  child: const Text('Выйти из клуба'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

Widget _errorCard(BuildContext context, String error, VoidCallback retry) =>
    Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(error),
            TextButton(
              onPressed: retry,
              child: const Text('Повторить загрузку'),
            ),
          ],
        ),
      ),
    );

Future<String?> _textDialog(
  BuildContext context,
  String title,
  String label, {
  int maxLength = 80,
}) async {
  final input = TextEditingController();
  final form = GlobalKey<FormState>();
  final result = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: Form(
        key: form,
        child: TextFormField(
          controller: input,
          maxLength: maxLength,
          decoration: InputDecoration(labelText: label),
          validator: (s) =>
              s == null || s.trim().isEmpty ? 'Введите значение' : null,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            if (form.currentState!.validate())
              Navigator.pop(dialog, input.text.trim());
          },
          child: const Text('Продолжить'),
        ),
      ],
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  input.dispose();
  return result;
}

Future<Map<String, dynamic>?> _clubEditor(
  BuildContext context, {
  Map<String, dynamic>? initial,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  builder: (_) => _ClubEditor(initial: initial),
);

class _ClubEditor extends StatefulWidget {
  const _ClubEditor({this.initial});
  final Map<String, dynamic>? initial;
  @override
  State<_ClubEditor> createState() => _ClubEditorState();
}

class _ClubEditorState extends State<_ClubEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(
    text: widget.initial?['name']?.toString(),
  );
  late final description = TextEditingController(
    text: widget.initial?['description']?.toString(),
  );
  late bool open = widget.initial?['is_open'] != false;
  @override
  void dispose() {
    name.dispose();
    description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? 'Новый клуб' : 'Настройки клуба'),
    content: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: name,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Название клуба'),
              validator: (v) =>
                  (v?.trim().length ?? 0) < 3 ? 'Не менее 3 символов' : null,
            ),
            TextFormField(
              controller: description,
              maxLength: 2000,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'О клубе, городе и интересах',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: open,
              onChanged: (v) => setState(() => open = v),
              title: const Text('Открытое вступление'),
              subtitle: Text(
                open
                    ? 'Клуб можно найти в общем списке.'
                    : 'Вход только по коду приглашения.',
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate())
            Navigator.pop(context, {
              'name': name.text.trim(),
              'description': description.text.trim(),
              'is_open': open,
            });
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
}

class _ClubEventEditor extends StatefulWidget {
  const _ClubEventEditor({this.initial});
  final Map<String, dynamic>? initial;
  @override
  State<_ClubEventEditor> createState() => _ClubEventEditorState();
}

class _ClubEventEditorState extends State<_ClubEventEditor> {
  final form = GlobalKey<FormState>();
  late final title = TextEditingController(
    text: widget.initial?['title']?.toString(),
  );
  late final description = TextEditingController(
    text: widget.initial?['description']?.toString(),
  );
  late DateTime date =
      DateTime.tryParse('${widget.initial?['starts_at']}')?.toLocal() ??
      DateTime.now().add(const Duration(days: 1));
  @override
  void dispose() {
    title.dispose();
    description.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final day = await showDatePicker(
      context: context,
      initialDate: date.isBefore(DateTime.now()) ? DateTime.now() : date,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(date),
    );
    if (time != null && mounted)
      setState(
        () => date = DateTime(
          day.year,
          day.month,
          day.day,
          time.hour,
          time.minute,
        ),
      );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Клубное событие'),
    content: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: title,
              maxLength: 100,
              decoration: const InputDecoration(labelText: 'Название'),
              validator: (s) =>
                  (s?.trim().length ?? 0) < 3 ? 'Не менее 3 символов' : null,
            ),
            TextFormField(
              controller: description,
              maxLength: 2000,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Где встречаемся и что планируем',
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event),
              title: Text(_date(date.toIso8601String())),
              subtitle: const Text('Время на вашем устройстве'),
              onTap: _pick,
            ),
            if (!date.isAfter(DateTime.now()))
              Text(
                'Нужно будущее время',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate() && date.isAfter(DateTime.now()))
            Navigator.pop(context, {
              'id': widget.initial?['id'] ?? newRideId(),
              'title': title.text.trim(),
              'description': description.text.trim(),
              'starts_at': date.toUtc().toIso8601String(),
            });
        },
        child: const Text('Создать событие'),
      ),
    ],
  );
}
