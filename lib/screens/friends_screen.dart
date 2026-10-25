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

  const FriendsScreen({super.key, this.navigationController});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen>
    with SingleTickerProviderStateMixin {
  final FriendService _friendService = FriendService();
  final ChatService _chatService = ChatService();
  final TextEditingController _searchController = TextEditingController();
  late final TabController _tabController;

  bool _isLoading = true;
  List<FriendProfile> _friends = [];
  List<FriendRequest> _incoming = [];
  List<FriendRequest> _outgoing = [];
  List<FriendProfile> _searchResults = [];
  bool _searching = false;
  String? _busyUserId; // идёт обработка кнопки у этого пользователя

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cached = await _friendService.loadCachedFriends();
    if (!mounted) return;
    if (cached != null) {
      setState(() {
        _friends = cached;
        _isLoading = false;
      });
    } else if (_friends.isEmpty) {
      setState(() => _isLoading = true);
    }
    final (friends, incoming, outgoing) = await (
      _friendService.fetchFriends(),
      _friendService.fetchIncomingRequests(),
      _friendService.fetchOutgoingRequests(),
    ).wait;
    if (!mounted) return;
    setState(() {
      _friends = friends;
      _incoming = incoming;
      _outgoing = outgoing;
      _isLoading = false;
    });
  }

  /// После изменений обновляем и кэш друзей на карте.
  Future<void> _reloadAll() async {
    await widget.navigationController?.refreshFriends();
    await _load();
  }

  Future<void> _search(String query) async {
    if (query.trim().length < 2) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() => _searching = true);
    final results = await _friendService.searchUsers(query);
    if (!mounted) return;
    setState(() {
      _searchResults = results;
      _searching = false;
    });
  }

  Future<void> _addFriend(FriendProfile user) async {
    setState(() => _busyUserId = user.id);
    try {
      await _friendService.sendRequest(user.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Заявка отправлена: ${user.username}')),
      );
      await _load();
    } on FriendServiceException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  Future<void> _accept(FriendRequest request) async {
    setState(() => _busyUserId = request.id);
    try {
      await _friendService.acceptRequest(request);
      await _reloadAll();
    } on FriendServiceException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  Future<void> _decline(FriendRequest request) async {
    await _friendService.declineRequest(request);
    await _reloadAll();
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
    if (confirmed != true) return;

    await _friendService.removeFriend(friend.id);
    await _reloadAll();
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
            const Tab(text: 'Поиск'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                const CommunityFeed(),
                _buildFriendsTab(),
                _buildRequestsTab(),
                _buildSearchTab(),
              ],
            ),
    );
  }

  // ── Вкладка «Друзья» ──────────────────────────────────────────────

  Widget _buildFriendsTab() {
    if (_friends.isEmpty) {
      return _buildEmptyState(
        icon: Icons.group_outlined,
        title: 'Друзей пока нет',
        subtitle:
            'Найдите райдеров во вкладке «Поиск».\nВо время заезда '
            'друзья будут видеть вас на карте.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: _friends.map(_buildFriendTile).toList(),
      ),
    );
  }

  Widget _buildFriendTile(FriendProfile friend) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Stack(
          children: [
            _buildAvatar(friend.avatarUrl, friend.username),
            if (friend.hasLivePosition)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: friend.isLive ? Colors.green : Colors.grey,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
          ],
        ),
        title: Text(
          friend.username,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: ListenableBuilder(
          listenable: PresenceService.instance,
          builder: (_, __) => Text(
            '${PresenceService.instance.statusText(friend.id)} · ${friend.isLive
                ? 'Сейчас в заезде — виден на карте'
                : friend.hasLivePosition
                ? 'На карте · позиция: ${friend.positionAgeText}'
                : (friend.city != null && friend.city!.isNotEmpty ? friend.city! : 'Позиция пока недоступна')}',
            style: TextStyle(
              fontSize: 12,
              color: friend.isLive ? Colors.green : Colors.grey,
            ),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Чат с другом.
            IconButton(
              tooltip: 'Написать',
              icon: const Icon(
                Icons.chat_bubble_outline,
                color: Colors.deepOrange,
              ),
              onPressed: () => _openChat(friend),
            ),
            IconButton(
              tooltip: 'Удалить из друзей',
              icon: const Icon(
                Icons.person_remove_outlined,
                color: Colors.grey,
              ),
              onPressed: () => _removeFriend(friend),
            ),
          ],
        ),
        // Тап по другу — публичный профиль (там статус «вы друзья»).
        onTap: () => _openPublicProfile(friend),
      ),
    );
  }

  // ── Вкладка «Заявки» ──────────────────────────────────────────────

  Widget _buildRequestsTab() {
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
          if (_incoming.isNotEmpty) ...[
            const Text(
              'Входящие',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            ..._incoming.map(_buildIncomingRequest),
          ],
          if (_outgoing.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Отправленные',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            ..._outgoing.map(_buildOutgoingRequest),
          ],
        ],
      ),
    );
  }

  Widget _buildIncomingRequest(FriendRequest request) {
    final busy = _busyUserId == request.id;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: _buildAvatar(request.fromAvatarUrl, request.fromUsername),
        title: Text(
          request.fromUsername,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: const Text('Хочет добавить вас в друзья'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Принять',
              icon: busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle, color: Colors.deepOrange),
              onPressed: busy ? null : () => _accept(request),
            ),
            IconButton(
              tooltip: 'Отклонить',
              icon: const Icon(Icons.delete_outline, color: Colors.grey),
              onPressed: busy ? null : () => _decline(request),
            ),
          ],
        ),
        onTap: () => _openPublicProfileById(
          request.fromUserId,
          FriendProfile(
            id: request.fromUserId,
            username: request.fromUsername,
            avatarUrl: request.fromAvatarUrl,
          ),
        ),
      ),
    );
  }

  Widget _buildOutgoingRequest(FriendRequest request) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: _buildAvatar(request.toAvatarUrl, request.toUsername),
        title: Text(request.toUsername),
        subtitle: const Text('Ожидает подтверждения'),
        trailing: IconButton(
          tooltip: 'Отозвать',
          icon: const Icon(Icons.close, color: Colors.grey),
          onPressed: () => _decline(request),
        ),
        onTap: () => _openPublicProfileById(
          request.toUserId,
          FriendProfile(
            id: request.toUserId,
            username: request.toUsername,
            avatarUrl: request.toAvatarUrl,
          ),
        ),
      ),
    );
  }

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
              : _searchResults.isEmpty
              ? _buildEmptyState(
                  icon: Icons.search,
                  title: _searchController.text.trim().length < 2
                      ? 'Введите имя райдера'
                      : 'Никого не нашли',
                  subtitle: 'Имя берётся из профиля пользователя',
                )
              : RefreshIndicator(
                  onRefresh: _load,
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
    final busy = _busyUserId == user.id;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: _buildAvatar(user.avatarUrl, user.username),
        title: Text(
          user.username,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: user.city != null && user.city!.isNotEmpty
            ? Text(user.city!)
            : null,
        // Тап — публичный профиль райдера.
        onTap: () => _openPublicProfile(user),
        trailing: isFriend
            ? const Tooltip(
                message: 'Уже друзья',
                child: Icon(Icons.check_circle, color: Colors.deepOrange),
              )
            : alreadyRequested
            ? const Text(
                'Заявка\nотправлена',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey),
              )
            : ElevatedButton.icon(
                onPressed: busy ? null : () => _addFriend(user),
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.person_add_alt_1, size: 18),
                label: const Text('Добавить'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepOrange,
                  foregroundColor: Colors.white,
                ),
              ),
      ),
    );
  }

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
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
