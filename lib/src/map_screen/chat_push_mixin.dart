part of '../../main.dart';

/// Push-уведомления и баннер входящего сообщения на карте.
mixin _ChatPushMixin on _MapScreenStateBase {
  // Product policy: chat messages never use an in-app overlay on any platform.
  bool get _systemChatNotificationsOnly => true;
  Future<bool> _previewPushMessage(String messageId) async {
    if (!mounted || !_isForeground) return false;
    final owner = _chatService.userId;
    final message = await _chatService.fetchMessage(messageId);
    if (!mounted ||
        !_isForeground ||
        owner != _chatService.userId ||
        message == null ||
        message.receiverId != owner) {
      return false;
    }
    if (message.isRead || ChatService.openChatFriendId == message.senderId) {
      return true;
    }
    final notification = await NotificationService.instance
        .notifyIncomingMessage(message);
    if (!mounted || !_isForeground || owner != _chatService.userId) {
      return false;
    }
    if (notification != null) _showIncomingBanner(notification, message);
    return true;
  }

  Future<void> _initialisePush() async {
    await PushService.instance.init();
    if (mounted && !_pushErrorShown && PushService.instance.lastError != null) {
      _pushErrorShown = true;
      _showSnackBar(
        'Push-уведомления недоступны: проверьте разрешение и настройку сервера',
      );
    }
  }

  /// Тап по системному push: открываем чат с отправителем.
  Future<void> _openChatFromPush(String senderId) async {
    if (!mounted ||
        _openingPushChat ||
        _chatService.userId == null ||
        ChatService.openChatFriendId == senderId) {
      return;
    }
    _openingPushChat = true;
    final owner = _chatService.userId;
    try {
      // Validate recipient access using authenticated data, not push payload alone.
      final friends = await FriendService().fetchFriends();
      if (!mounted || !friends.any((f) => f.id == senderId)) return;
      final friend = await FriendService().fetchPublicProfile(senderId);
      if (!mounted || friend == null || owner != _chatService.userId) return;
      await PushService.instance.clearChatNotification(owner!, senderId);
      if (!mounted) return;
      final opened = Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ChatScreen(friend: friend)),
      );
      unawaited(
        opened.then((_) async {
          if (!mounted) return;
          await _chatService.refreshUnread();
          await NotificationService.instance.refresh();
        }),
      );
    } finally {
      _openingPushChat = false;
    }
  }

  void _ensureIncomingOverlay() {
    if (_systemChatNotificationsOnly) return;
    if (!mounted || _incomingOverlay != null || !_isForeground) return;
    _incomingOverlay = OverlayEntry(
      builder: (overlayContext) => IncomingChatPreview(
        items: _incomingMessages,
        visible: _incomingVisible,
        onRead: (item) async {
          if (item.message.receiverId != _chatService.userId) {
            throw const ChatServiceException('Сменился аккаунт');
          }
          final ok = await _chatService.markMessageRead(item.message);
          if (!ok) throw const ChatServiceException('Нет соединения');
          await _chatService.refreshUnread();
          await NotificationService.instance.refresh();
        },
        onReply: (item, text, id) async {
          final owner = _chatService.userId;
          if (owner == null || owner != item.message.receiverId) {
            throw const ChatServiceException('Сменился аккаунт');
          }
          final sent = await _chatService.sendMessage(
            item.message.senderId,
            text: text,
            replyToId: item.message.id,
            messageId: id,
            retry: true,
          );
          if (sent == null) {
            throw const ChatServiceException('Ответ не отправлен');
          }
          if (_chatService.userId == owner) {
            await _chatService.markMessageRead(item.message);
            await _chatService.refreshUnread();
            await NotificationService.instance.refresh();
          }
        },
        onOpen: (item) => _openChatFromPush(item.message.senderId),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_incomingOverlay!);
  }

  void _showIncomingBanner(AppNotification notification, ChatMessage message) {
    if (!mounted ||
        !_isForeground ||
        message.receiverId != _chatService.userId ||
        !_previewedMessageIds.add(message.id)) {
      return;
    }
    if (_previewedMessageIds.length > 1000) {
      _previewedMessageIds.remove(_previewedMessageIds.first);
    }
    if (_systemChatNotificationsOnly ||
        !kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      unawaited(PushService.instance.showIncomingChat(notification, message));
      return;
    }
    _incomingMessages.value = [
      ..._incomingMessages.value.where(
        (item) => item.message.receiverId == message.receiverId,
      ),
      IncomingChatItem(
        message,
        notification.title.replaceFirst('Новое сообщение от ', ''),
        notification.subtitle,
      ),
    ];
    _ensureIncomingOverlay();
    if (_incomingOverlay != null) {
      Overlay.of(context, rootOverlay: true).rearrange([_incomingOverlay!]);
    }
  }
}
