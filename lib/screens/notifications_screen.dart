import 'package:flutter/material.dart';

import '../services/chat_service.dart';
import '../services/friend_service.dart';
import '../services/notification_service.dart';
import 'chat_screen.dart';
import 'friends_screen.dart';

/// Центр уведомлений: новые сообщения, заявки в друзья, системные события.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final NotificationService _notificationService = NotificationService.instance;
  final ChatService _chatService = ChatService();
  final FriendService _friendService = FriendService();

  /// Первая загрузка: пока [refresh] не соберёт список — спиннер.
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _notificationService.addListener(_onNotificationsChanged);
    // Раньше refresh() вызывался без setState — список оставался пустым
    // до первого pull-to-refresh. Теперь экран перерисовывается по готовности.
    _refresh();
  }

  void _onNotificationsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _notificationService.removeListener(_onNotificationsChanged);
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    await _notificationService.refresh();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _openItem(AppNotification item) async {
    switch (item.type) {
      case AppNotificationType.chat:
        if (item.payloadUserId == null) break;
        // Чату нужен полный FriendProfile — подтягиваем публичный профиль.
        final profile = await _friendService.fetchPublicProfile(
          item.payloadUserId!,
        );
        if (!mounted) break;
        if (profile == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Профиль отправителя недоступен')),
          );
          break;
        }
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => ChatScreen(friend: profile)),
        ).then((_) {
          if (!mounted) return;
          _chatService.refreshUnread();
          _refresh();
        });
        break;
      case AppNotificationType.friendRequest:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const FriendsScreen()),
        ).then((_) {
          if (mounted) _refresh();
        });
        break;
      case AppNotificationType.system:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _notificationService.items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Уведомления'),
        centerTitle: true,
        actions: [
          if (items.isNotEmpty)
            TextButton(
              onPressed: () {
                _notificationService.clearAll();
                setState(() {});
              },
              child: const Text('Скрыть'),
            ),
        ],
      ),
      body: _loading && items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.notifications_none, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'Уведомлений нет',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Здесь появятся сообщения, заявки\nв друзья и события приложения',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: items.map(_buildTile).toList(),
              ),
            ),
    );
  }

  Widget _buildTile(AppNotification item) {
    final (icon, color) = switch (item.type) {
      AppNotificationType.chat => (
        Icons.chat_bubble_outline,
        Colors.deepOrange,
      ),
      AppNotificationType.friendRequest => (
        Icons.person_add_alt_1,
        Colors.blue,
      ),
      AppNotificationType.system => (Icons.info_outline, Colors.grey),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.12),
          child: Icon(icon, color: color, size: 22),
        ),
        title: Text(
          item.title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        subtitle: item.subtitle.isEmpty
            ? null
            : Text(
                item.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
        trailing: Text(
          _timeAgo(item.createdAt),
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        onTap: item.type == AppNotificationType.system
            ? null
            : () => _openItem(item),
      ),
    );
  }

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time.toLocal());
    if (diff.inMinutes < 1) return 'сейчас';
    if (diff.inMinutes < 60) return '${diff.inMinutes} мин';
    if (diff.inHours < 24) return '${diff.inHours} ч';
    return '${diff.inDays} дн';
  }
}
