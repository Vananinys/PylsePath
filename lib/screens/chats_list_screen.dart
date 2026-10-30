import 'dart:async';

import '../data/ui_snapshot_cache.dart';
import '../data/user_scope.dart';

import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../models/friend_profile.dart';
import '../services/chat_service.dart';
import '../services/friend_service.dart';
import 'chat_screen.dart';

/// Список диалогов: друзья с последним сообщением, временем и счётчиком
/// непрочитанных. Бейдж непрочитанных по каждому другу.
class ChatsListScreen extends StatefulWidget {
  const ChatsListScreen({super.key});

  @override
  State<ChatsListScreen> createState() => _ChatsListScreenState();
}

class _ChatsListScreenState extends State<ChatsListScreen> {
  final ChatService _chatService = ChatService();
  final FriendService _friendService = FriendService();

  bool _isLoading = true;
  List<_DialogEntry> _dialogs = [];
  String _query = '';
  String? _error;
  Timer? _refreshTimer;
  bool _loadingRemote = false;
  final String? _owner = UserScope.currentUserId();

  @override
  void initState() {
    super.initState();
    _chatService.subscribe(_onMessage);
    _load();
  }

  void _onMessage(ChatMessage message) {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 300), _load);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _chatService.unsubscribe(_onMessage);
    super.dispose();
  }

  Future<void> _load() async {
    if (_loadingRemote) return;
    _loadingRemote = true;
    final cache = UiSnapshotCache('chat_dialogs', _owner);
    if (_isLoading) {
      final rows = await cache.read();
      if (!mounted || UserScope.currentUserId() != _owner) {
        _loadingRemote = false;
        return;
      }
      if (rows != null) {
        try {
          setState(() {
            _dialogs = rows
                .map(
                  (row) => _DialogEntry(
                    friend: FriendProfile.fromRow(
                      Map<String, dynamic>.from(row['friend'] as Map),
                    ),
                    lastMessage: row['message'] == null
                        ? null
                        : ChatMessage.fromRow(
                            Map<String, dynamic>.from(row['message'] as Map),
                          ),
                    unread: row['unread'] as int? ?? 0,
                  ),
                )
                .toList();
            _isLoading = false;
          });
        } catch (_) {
          /* A network response replaces malformed snapshots. */
        }
      }
    }
    try {
      final (friends, unreadByFriend) = await (
        _friendService.fetchFriends(),
        _chatService.unreadByFriend(strict: true),
      ).wait;
      // Each chat supplies its own latest message; active conversations cannot
      // push quiet friends beyond a global, unrelated-message limit.
      final recent = await Future.wait(
        friends.map(
          (friend) => _chatService.fetchLatestWith(friend.id, strict: true),
        ),
      );
      final lastByFriend = <String, ChatMessage>{};
      for (final message in recent.whereType<ChatMessage>()) {
        final counterpart = message.senderId == _chatService.userId
            ? message.receiverId
            : message.senderId;
        lastByFriend.putIfAbsent(counterpart, () => message);
      }

      final dialogs =
          friends
              .map(
                (friend) => _DialogEntry(
                  friend: friend,
                  lastMessage: lastByFriend[friend.id],
                  unread: unreadByFriend[friend.id] ?? 0,
                ),
              )
              .toList()
            ..sort((a, b) {
              // Сначала диалоги с непрочитанными, затем по свежести.
              if (a.unread != b.unread) return b.unread.compareTo(a.unread);
              final aTime = a.lastMessage?.createdAt ?? DateTime(2000);
              final bTime = b.lastMessage?.createdAt ?? DateTime(2000);
              return bTime.compareTo(aTime);
            });

      if (!mounted || UserScope.currentUserId() != _owner) return;
      setState(() {
        _error = null;
        _dialogs = dialogs;
        _isLoading = false;
      });
      await cache.write(
        dialogs
            .map(
              (entry) => <String, dynamic>{
                'friend': {
                  'id': entry.friend.id,
                  'username': entry.friend.username,
                  'avatar_url': entry.friend.avatarUrl,
                },
                'message': entry.lastMessage?.toRow(),
                'unread': entry.unread,
              },
            )
            .toList(),
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Не удалось обновить диалоги';
        });
      }
    } finally {
      _loadingRemote = false;
    }
  }

  Future<void> _openChat(_DialogEntry entry) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ChatScreen(friend: entry.friend)),
    );
    await _chatService.refreshUnread();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _dialogs
        .where(
          (entry) =>
              _query.isEmpty ||
              entry.friend.username.toLowerCase().contains(_query) ||
              (entry.lastMessage?.body?.toLowerCase().contains(_query) ??
                  false),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Сообщения'),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(62),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              onChanged: (value) =>
                  setState(() => _query = value.toLowerCase().trim()),
              decoration: InputDecoration(
                hintText: 'Поиск по имени и последнему сообщению',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(onPressed: _load, child: const Text('Повторить')),
              ],
            ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _dialogs.isEmpty
                ? (_error == null
                      ? _buildEmptyState()
                      : const Center(child: Text('Диалоги не загружены')))
                : shown.isEmpty
                ? const Center(child: Text('Диалоги не найдены'))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.all(12),
                      children: shown.map(_buildDialogTile).toList(),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildDialogTile(_DialogEntry entry) {
    final last = entry.lastMessage;
    final hasPhoto =
        entry.friend.avatarUrl != null &&
        (entry.friend.avatarUrl!.startsWith('http://') ||
            entry.friend.avatarUrl!.startsWith('https://'));

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Stack(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: Colors.deepOrange.shade50,
              backgroundImage: hasPhoto
                  ? NetworkImage(entry.friend.avatarUrl!)
                  : null,
              child: hasPhoto
                  ? null
                  : Text(
                      entry.friend.username.isEmpty
                          ? 'Р'
                          : entry.friend.username.characters.first
                                .toUpperCase(),
                      style: const TextStyle(
                        color: Colors.deepOrange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
            if (entry.unread > 0)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.deepOrange,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Text(
                    '${entry.unread}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
        ),
        title: Text(
          entry.friend.username,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          last == null
              ? 'Диалог ещё не начат'
              : (last.isVideo
                    ? 'Видео'
                    : last.isPhoto
                    ? 'Фото'
                    : last.isVoice
                    ? 'Голосовое сообщение'
                    : last.isStickerOnly
                    ? 'Стикер ${last.sticker}'
                    : last.body ?? ''),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            color: entry.unread > 0
                ? Theme.of(context).colorScheme.onSurface
                : Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: entry.unread > 0 ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        trailing: last == null
            ? Icon(
                Icons.chat_bubble_outline,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              )
            : Text(
                _formatTime(last.createdAt),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
        onTap: () => _openChat(entry),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    final now = DateTime.now();
    final isToday =
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    String two(int v) => v.toString().padLeft(2, '0');
    if (isToday) return '${two(local.hour)}:${two(local.minute)}';
    return '${two(local.day)}.${two(local.month)}';
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.forum_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'Диалогов пока нет',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Добавьте друзей и напишите им —\nдиалог появится здесь',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogEntry {
  final FriendProfile friend;
  final ChatMessage? lastMessage;
  final int unread;

  const _DialogEntry({required this.friend, this.lastMessage, this.unread = 0});
}
