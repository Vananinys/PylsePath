import 'dart:async';

import 'package:flutter/material.dart';

import '../services/presence_service.dart';

import '../controllers/map_navigation_controller.dart';
import '../models/friend_profile.dart';
import '../services/chat_service.dart';
import '../services/friend_service.dart';
import '../widgets/community_feed.dart';
import 'chat_screen.dart';
import 'public_profile_screen.dart';

/// Экран сообщества: вкладки «Лента» / «Друзья» / «Заявки» / «Поиск».
///
/// Из поиска и из заявок можно открыть публичный профиль райдера и
/// отправить заявку. Во время заезда друзья видят вашу позицию на карте
/// (и вы — их).
class FriendsScreen extends StatefulWidget {
  final MapNavigationController? navigationController;

  const FriendsScreen({
    super.key,
    this.navigationController,
    this.friendService,
  });
  final FriendService? friendService;

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen>
    with SingleTickerProviderStateMixin {
  late final FriendService _friendService;
  late final String? _screenOwner;
  bool get _sameOwner => _friendService.userId == _screenOwner;
  final ChatService _chatService = ChatService();
  final TextEditingController _searchController = TextEditingController();
  late final TabController _tabController;

  bool _isLoading = true, _requestsLoading = true;
  bool _cachedFriends = false;
  String? _friendsError, _requestsError, _searchError;
  int _friendsGeneration = 0, _requestsGeneration = 0, _searchGeneration = 0;
  Timer? _searchDebounce;
  List<FriendProfile> _friends = [];
  List<FriendRequest> _incoming = [];
  List<FriendRequest> _outgoing = [];
  List<FriendProfile> _searchResults = [];
  bool _searching = false;
  String? _busyUserId; // идёт обработка кнопки у этого пользователя

  @override
  void initState() {
    super.initState();
    _friendService = widget.friendService ?? FriendService();
    _screenOwner = _friendService.userId;
    _tabController = TabController(length: 4, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await Future.wait([_loadFriends(), _loadRequests()]);
  }

  Future<void> _loadFriends() async {
    final generation = ++_friendsGeneration, owner = _friendService.userId;
    bool current() =>
        mounted &&
        _sameOwner &&
        generation == _friendsGeneration &&
        owner == _friendService.userId;
    try {
      if (_isLoading) {
        final cached = await _friendService.loadCachedFriends();
        if (!current()) return;
        if (cached != null)
          setState(() {
            _friends = cached;
            _cachedFriends = true;
            _isLoading = false;
          });
      }
      final friends = await _friendService.fetchFriends(strict: true);
      if (!current()) return;
      setState(() {
        _friends = friends;
        _friendsError = null;
        _cachedFriends = false;
      });
    } catch (_) {
      if (current())
        setState(() => _friendsError = 'Не удалось обновить друзей.');
    } finally {
      if (current()) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadRequests() async {
    final generation = ++_requestsGeneration, owner = _friendService.userId;
    bool current() =>
        mounted &&
        _sameOwner &&
        generation == _requestsGeneration &&
        owner == _friendService.userId;
    try {
      final values = await Future.wait([
        _friendService.fetchIncomingRequests(strict: true),
        _friendService.fetchOutgoingRequests(strict: true),
      ]);
      if (!current()) return;
      setState(() {
        _incoming = values[0];
        _outgoing = values[1];
        _requestsError = null;
      });
    } catch (_) {
      if (current())
        setState(() => _requestsError = 'Не удалось обновить заявки.');
    } finally {
      if (current()) setState(() => _requestsLoading = false);
    }
  }

  Future<void> _reloadAll() async {
    await _load();
    await widget.navigationController?.refreshFriends();
  }

  Future<void> _search(String query, {bool debounce = true}) async {
    if (!_sameOwner) return;
    _searchDebounce?.cancel();
    final generation = ++_searchGeneration;
    final cleaned = query.trim();
    setState(() {
      _searchResults = [];
      _searchError = null;
      _searching = cleaned.length >= 2;
    });
    if (cleaned.length < 2) return;
    if (!debounce) return _runSearch(cleaned, generation);
    _searchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _runSearch(cleaned, generation),
    );
  }

  Future<void> _runSearch(String query, int generation) async {
    final owner = _friendService.userId;
    bool current() =>
        mounted &&
        _sameOwner &&
        generation == _searchGeneration &&
        owner == _friendService.userId;
    try {
      final results = await _friendService.searchUsers(query, strict: true);
      if (current()) setState(() => _searchResults = results);
    } catch (_) {
      if (current())
        setState(() => _searchError = 'Поиск недоступен. Попробуйте ещё раз.');
    } finally {
      if (current()) setState(() => _searching = false);
    }
  }

  Future<void> _addFriend(FriendProfile user) async {
    if (!_sameOwner || _busyUserId != null) return;
    setState(() => _busyUserId = user.id);
    try {
      await _friendService.sendRequest(user.id);
      if (!mounted || !_sameOwner) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Заявка отправлена: ${user.username}')),
      );
      await _load();
    } on FriendServiceException catch (error) {
      if (!mounted || !_sameOwner) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  Future<void> _accept(FriendRequest request) async {
    if (!_sameOwner || _busyUserId != null) return;
    setState(() => _busyUserId = request.id);
    try {
      await _friendService.acceptRequest(request);
      await _reloadAll();
    } on FriendServiceException catch (error) {
      if (!mounted || !_sameOwner) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  Future<void> _decline(FriendRequest request) async {
    if (!_sameOwner || _busyUserId != null) return;
    setState(() => _busyUserId = request.id);
    try {
      await _friendService.declineRequest(request);
      await _reloadAll();
    } on FriendServiceException catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  Future<void> _removeFriend(FriendProfile friend) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить из друзей?'),
        content: Text(
          '«${friend.username}» больше не будет видеть вас на карте.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !_sameOwner) return;

    if (!mounted || _busyUserId != null) return;
    setState(() => _busyUserId = friend.id);
    try {
      await _friendService.removeFriend(friend.id, strict: true);
      await _reloadAll();
    } on FriendServiceException catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  Future<void> _openChat(FriendProfile friend) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ChatScreen(friend: friend)),
    );
    await _chatService.refreshUnread();
  }

  @override
  Widget build(BuildContext context) {
    if (!_sameOwner)
      return const Scaffold(
        body: Center(
          child: Text('Аккаунт изменился. Откройте сообщество заново.'),
        ),
      );
    final incomingCount = _incoming.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Сообщество'),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.deepOrange,
          unselectedLabelColor: Colors.grey,
          indicatorColor: Colors.deepOrange,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            const Tab(text: 'Лента'),
            const Tab(text: 'Друзья'),
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Заявки'),
                  if (incomingCount > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.deepOrange,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$incomingCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Tab(text: 'Поиск людей'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          CommunityFeed(onFindFriends: () => _tabController.animateTo(3)),
          _buildFriendsTab(),
          _buildRequestsTab(),
          _buildSearchTab(),
        ],
      ),
    );
  }

  // ── Вкладка «Друзья» ──────────────────────────────────────────────

  Widget _buildFriendsTab() {
    if (_isLoading && _friends.isEmpty)
      return const Center(child: CircularProgressIndicator());
    if (_friendsError != null && _friends.isEmpty)
      return _status(_friendsError!, _loadFriends);

    if (_friends.isEmpty) {
      return _buildEmptyState(
        icon: Icons.group_outlined,
        title: 'Друзей пока нет',
        action: () => _tabController.animateTo(3),
        subtitle:
            'Найдите райдеров во вкладке «Поиск».\nВо время заезда '
            'друзья будут видеть вас на карте.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_friendsError != null) _status(_friendsError!, _loadFriends),
          if (_cachedFriends)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text("Сохранённый список друзей"),
            ),
          ..._friends.map(_buildFriendTile),
        ],
      ),
    );
  }

  Widget _buildFriendTile(FriendProfile friend) => _personCard(
    avatar: _buildAvatar(friend.avatarUrl, friend.username),
    name: friend.username,
    details: ListenableBuilder(
      listenable: PresenceService.instance,
      builder: (_, __) => Text(
        '${PresenceService.instance.statusText(friend.id)} · ${friend.isLive
            ? 'Сейчас в заезде — виден на карте'
            : friend.hasLivePosition
            ? 'На карте · позиция: ${friend.positionAgeText}'
            : friend.city ?? 'Позиция пока недоступна'}',
      ),
    ),
    onOpen: () => _openPublicProfile(friend),
    actions: [
      TextButton.icon(
        onPressed: _busyUserId != null ? null : () => _openChat(friend),
        icon: const Icon(Icons.chat_bubble_outline),
        label: const Text('Написать'),
      ),
      PopupMenuButton<String>(
        tooltip: 'Действия с другом',
        enabled: _busyUserId == null,
        onSelected: (_) => _removeFriend(friend),
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'remove',
            child: Text('Удалить из друзей'),
          ),
        ],
      ),
      if (_busyUserId == friend.id)
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
    ],
  );

  // ── Вкладка «Заявки» ──────────────────────────────────────────────

  Widget _buildRequestsTab() {
    if (_requestsLoading)
      return const Center(child: CircularProgressIndicator());
    if (_requestsError != null && _incoming.isEmpty && _outgoing.isEmpty)
      return _status(_requestsError!, _loadRequests);

    if (_incoming.isEmpty && _outgoing.isEmpty) {
      return _buildEmptyState(
        icon: Icons.mark_email_unread_outlined,
        title: 'Заявок нет',
        subtitle: 'Входящие и отправленные заявки появятся здесь',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_requestsError != null) _status(_requestsError!, _loadRequests),
          if (_incoming.isNotEmpty) ...[
            Text(
              'Входящие',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            ..._incoming.map(_buildIncomingRequest),
          ],
          if (_outgoing.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Отправленные',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            ..._outgoing.map(_buildOutgoingRequest),
          ],
        ],
      ),
    );
  }

  Widget _buildIncomingRequest(FriendRequest request) => _personCard(
    avatar: _buildAvatar(request.fromAvatarUrl, request.fromUsername),
    name: request.fromUsername,
    details: const Text('Хочет добавить вас в друзья'),
    onOpen: () => _openPublicProfileById(
      request.fromUserId,
      FriendProfile(
        id: request.fromUserId,
        username: request.fromUsername,
        avatarUrl: request.fromAvatarUrl,
      ),
    ),
    actions: [
      FilledButton.icon(
        onPressed: _busyUserId != null ? null : () => _accept(request),
        icon: const Icon(Icons.check),
        label: const Text('Принять'),
      ),
      TextButton(
        onPressed: _busyUserId != null ? null : () => _decline(request),
        child: const Text('Отклонить'),
      ),
      if (_busyUserId == request.id)
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
    ],
  );
  Widget _buildOutgoingRequest(FriendRequest request) => _personCard(
    avatar: _buildAvatar(request.toAvatarUrl, request.toUsername),
    name: request.toUsername,
    details: const Text('Заявка отправлена · ожидает подтверждения'),
    onOpen: () => _openPublicProfileById(
      request.toUserId,
      FriendProfile(
        id: request.toUserId,
        username: request.toUsername,
        avatarUrl: request.toAvatarUrl,
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busyUserId != null ? null : () => _decline(request),
        child: const Text('Отозвать заявку'),
      ),
      if (_busyUserId == request.id)
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
    ],
  );

  // ── Вкладка «Поиск» ───────────────────────────────────────────────

  Widget _buildSearchTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Имя райдера (минимум 2 символа)...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : (_searchController.text.isNotEmpty
                        ? IconButton(
                            tooltip: 'Очистить поиск',
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              _search('');
                            },
                          )
                        : null),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onChanged: _search,
          ),
        ),
        Expanded(
          child: _searching
              ? const Center(child: CircularProgressIndicator())
              : _searchError != null
              ? _status(
                  _searchError!,
                  () => _search(_searchController.text, debounce: false),
                )
              : _searchResults.isEmpty
              ? _buildEmptyState(
                  icon: Icons.search,
                  title: _searchController.text.trim().length < 2
                      ? 'Введите имя райдера'
                      : 'Никого не нашли',
                  subtitle: 'Имя берётся из профиля пользователя',
                )
              : RefreshIndicator(
                  onRefresh: () =>
                      _search(_searchController.text, debounce: false),
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: _searchResults.map(_buildSearchResult).toList(),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildSearchResult(FriendProfile user) {
    final isFriend = _friends.any((friend) => friend.id == user.id);
    final alreadyRequested = _outgoing.any(
      (request) => request.toUserId == user.id,
    );
    return _personCard(
      avatar: _buildAvatar(user.avatarUrl, user.username),
      name: user.username,
      details: Text(
        user.city?.isNotEmpty == true ? user.city! : 'Райдер PulsePath',
      ),
      onOpen: () => _openPublicProfile(user),
      actions: [
        if (user.id == _screenOwner)
          const Text('Это вы')
        else if (isFriend)
          const Text('Вы друзья')
        else if (alreadyRequested)
          const Text('Заявка отправлена')
        else
          FilledButton.icon(
            onPressed: _busyUserId != null ? null : () => _addFriend(user),
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Добавить в друзья'),
          ),
        if (_busyUserId == user.id)
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _personCard({
    required Widget avatar,
    required String name,
    required Widget details,
    required VoidCallback onOpen,
    required List<Widget> actions,
  }) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final identity = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      details,
                    ],
                  );
                  final vertical =
                      constraints.maxWidth < 300 &&
                      MediaQuery.textScalerOf(context).scale(14) > 21;
                  if (vertical) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [avatar, const SizedBox(height: 8), identity],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      avatar,
                      const SizedBox(width: 12),
                      Expanded(child: identity),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: actions,
          ),
        ],
      ),
    ),
  );

  Future<void> _openPublicProfile(FriendProfile user) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            PublicProfileScreen(userId: user.id, preloaded: user),
      ),
    );
    // Статус мог измениться (заявка отправлена из профиля) — обновим.
    await _load();
  }

  Future<void> _openPublicProfileById(String userId, FriendProfile user) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            PublicProfileScreen(userId: userId, preloaded: user),
      ),
    );
    await _load();
  }

  Widget _status(String message, Future<void> Function() retry) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: retry,
              icon: const Icon(Icons.refresh),
              label: const Text('Повторить'),
            ),
          ],
        ),
      ),
    ),
  );

  // ── Общее ─────────────────────────────────────────────────────────

  Widget _buildAvatar(String? url, String name) {
    final hasUrl =
        url != null &&
        (url.startsWith('http://') || url.startsWith('https://'));
    return CircleAvatar(
      radius: 22,
      backgroundColor: Colors.deepOrange.shade50,
      backgroundImage: hasUrl ? NetworkImage(url) : null,
      child: hasUrl
          ? null
          : Text(
              name.isEmpty ? 'Р' : name.characters.first.toUpperCase(),
              style: const TextStyle(
                color: Colors.deepOrange,
                fontWeight: FontWeight.bold,
              ),
            ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? action,
  }) {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 56,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (action != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: FilledButton.icon(
                    onPressed: action,
                    icon: const Icon(Icons.person_search),
                    label: const Text('Найти людей'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
