import '../widgets/swipe_to_reply.dart';
import '../widgets/chat_message_text.dart';
import '../data/chat_local_store.dart';
import '../data/user_scope.dart';
import '../utils/ride_id.dart';
import '../widgets/chat_photo.dart';
import '../models/chat_media_draft.dart';
import '../widgets/chat_media_composer.dart';
import '../widgets/chat_video_player.dart';
import '../widgets/video_poster.dart';
import '../services/video_preview_service.dart';
import '../models/video_metadata.dart';
import '../utils/chat_media_files.dart';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../models/chat_message.dart';
import '../models/friend_profile.dart';
import '../services/chat_service.dart';
import '../services/presence_service.dart';
import '../models/shared_route.dart';
import '../widgets/shared_route_card.dart';
import '../widgets/chat_reply_preview.dart';
import '../widgets/route_share_sheet.dart';
import '../widgets/group_invitation_card.dart';
import '../widgets/group_invitation_sheet.dart';
import '../services/notification_service.dart';
import '../services/push_service.dart';
import 'public_profile_screen.dart';

/// Личная переписка с другом: текст + стикеры, живая доставка (Realtime),
/// отметка о прочтении.
class ChatScreen extends StatefulWidget {
  final FriendProfile friend;
  final ChatService? service;

  const ChatScreen({super.key, required this.friend, this.service});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  late final ChatService _chatService = widget.service ?? ChatService();
  late final ChatLocalStore _store = ChatLocalStore(
    UserScope.currentUserId(),
    widget.friend.id,
  );
  final TextEditingController _inputController = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  bool _mediaBusy = false;
  String? _mediaProgress;
  bool _cancelMediaPreparation = false;
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _recording = false;
  bool _recorderBusy = false;
  bool _blockedByMe = false;
  bool _blockedByThem = false;
  bool _foreground = true;
  bool _loadingPage = false;
  bool _markingRead = false;
  bool _hasMore = true;
  String? _loadError;
  int _newMessages = 0;
  String? _firstUnreadId;
  Timer? _draftTimer;
  Timer? _activityTimer;
  DateTime? _lastTypedAt;
  DateTime? _lastActivitySentAt;
  String _lastActivity = 'idle';

  void _composerChanged(String text) {
    _lastTypedAt = text.trim().isEmpty ? null : DateTime.now();
    _updateChatActivity();
  }

  void _updateChatActivity() {
    if (!mounted) return;
    final now = DateTime.now();
    final typing =
        _lastTypedAt != null &&
        now.difference(_lastTypedAt!) < const Duration(seconds: 4);
    final state = !_foreground || _blockedByMe || _blockedByThem
        ? 'idle'
        : _recording
        ? 'recording'
        : typing
        ? 'typing'
        : 'idle';
    if (state != _lastActivity ||
        (state != 'idle' &&
            (_lastActivitySentAt == null ||
                now.difference(_lastActivitySentAt!) >=
                    const Duration(seconds: 2)))) {
      _lastActivity = state;
      _lastActivitySentAt = now;
      unawaited(PresenceService.instance.setChatState(widget.friend.id, state));
    }
    if (state == 'idle') {
      _activityTimer?.cancel();
      _activityTimer = null;
    } else {
      _activityTimer ??= Timer.periodic(
        const Duration(seconds: 3),
        (_) => _updateChatActivity(),
      );
    }
  }

  Timer? _searchTimer;
  bool _searching = false;
  String _query = '';
  List<ChatMessage> _searchMessages = [];
  bool _searchBusy = false;
  bool _searchMore = false;
  int _searchGeneration = 0;
  final TextEditingController _searchController = TextEditingController();
  List<ChatMessage> get _visibleMessages =>
      _query.isEmpty ? _messages : _searchMessages;

  Timer? _recordTicker;
  ChatMessage? _replyingTo;
  String? _playingMessageId;
  StreamSubscription? _playerStateSubscription;
  final Stopwatch _recordStopwatch = Stopwatch();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  List<ChatMessage> _messages = [];
  final Map<String, ChatMessage> _replyTargets = {};
  bool _isLoading = true;
  bool _stickerPanelOpen = false;
  String _stickerCategory = 'Спорт';

  /// Кнопка «в конец переписки»: видна, когда пользователь отлистал вверх.
  bool _showScrollToBottom = false;

  void Function(ChatMessage message)? _listener;

  @override
  void initState() {
    super.initState();
    // Сообщаем глобальным уведомлениям, что этот диалог открыт на экране:
    // баннер «новое сообщение» для него показываться не будет.
    ChatService.openChatFriendId = widget.friend.id;
    NotificationService.instance.remove('chat_${widget.friend.id}');
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    _inputController.addListener(_draftChanged);
    _chatService.deletionListeners.add(_onDeleted);
    _chatService.connected.addListener(_connectionChanged);
    unawaited(_restoreLocal());
    unawaited(_loadBlockState());
    _subscribeRealtime();
    unawaited(_chatService.retryAttachmentCleanup());
  }

  /// reverse: true — offset 0 это НИЗ переписки (новые сообщения).
  /// Чем больше offset — тем выше к старым сообщениям.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final away = _scrollController.offset > 300;
    if (!away && _newMessages > 0 && mounted) setState(() => _newMessages = 0);
    if (!away && _foreground && _query.isEmpty) {
      unawaited(_markVisibleRead());
    }
    if (_scrollController.position.extentAfter < 250 &&
        !_isLoading &&
        _query.isEmpty &&
        _hasMore) {
      unawaited(_loadMessagesWithReactions(older: true));
    }
    if (away != _showScrollToBottom && mounted) {
      setState(() => _showScrollToBottom = away);
    }
  }

  @override
  void dispose() {
    _activityTimer?.cancel();
    unawaited(PresenceService.instance.setChatState(widget.friend.id, 'idle'));
    if (ChatService.openChatFriendId == widget.friend.id) {
      ChatService.openChatFriendId = null;
    }
    final listener = _listener;
    if (listener != null) _chatService.unsubscribe(listener);
    WidgetsBinding.instance.removeObserver(this);
    _chatService.deletionListeners.remove(_onDeleted);
    _chatService.connected.removeListener(_connectionChanged);
    _draftTimer?.cancel();
    _searchTimer?.cancel();
    unawaited(_store.saveDraft(_inputController.text));
    _searchController.dispose();
    _recorder.dispose();
    _recordTicker?.cancel();
    _audioPlayer.dispose();
    _playerStateSubscription?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _markVisibleRead() async {
    if (_markingRead ||
        !_foreground ||
        _query.isNotEmpty ||
        _showScrollToBottom ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    if (!_messages.any((m) => m.senderId == widget.friend.id && !m.isRead)) {
      return;
    }
    _markingRead = true;
    try {
      final ok = await _chatService.markRead(widget.friend.id);
      if (ok && mounted) {
        setState(
          () => _messages = _messages
              .map(
                (m) => m.senderId == widget.friend.id && !m.isRead
                    ? m.copyWith(readAt: DateTime.now().toUtc())
                    : m,
              )
              .toList(),
        );
        unawaited(_persistMessages());
        unawaited(_chatService.refreshUnread());
        final owner = _chatService.userId;
        if (owner != null) {
          unawaited(
            PushService.instance
                .clearChatNotification(owner, widget.friend.id)
                .catchError((Object error) {
                  debugPrint('[Chat] notification cleanup failed: $error');
                }),
          );
        }
      }
    } finally {
      _markingRead = false;
    }
  }

  void _draftChanged() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_store.saveDraft(_inputController.text));
    });
  }

  Future<void> _restoreLocal() async {
    final cached = await _store.readMessages();
    final draft = await _store.readDraft();
    if (!mounted) return;
    setState(() {
      if (cached.isNotEmpty) {
        _messages = _merge(cached, _messages);
        _isLoading = false;
      }
      if (_inputController.text.isEmpty) _inputController.text = draft;
    });
    await _loadMessagesWithReactions();
  }

  List<ChatMessage> _merge(
    Iterable<ChatMessage> old,
    Iterable<ChatMessage> fresh,
  ) {
    final byId = {
      for (final message in old) message.id: message,
      for (final message in fresh) message.id: message,
    };
    return byId.values.toList()..sort((a, b) {
      final date = a.createdAt.compareTo(b.createdAt);
      return date == 0 ? a.id.compareTo(b.id) : date;
    });
  }

  Future<void> _persistMessages() async {
    await _store.saveMessages(_messages);
  }

  void _onDeleted(String id) {
    if (!mounted ||
        (!_messages.any((m) => m.id == id) &&
            !_searchMessages.any((m) => m.id == id))) {
      return;
    }
    setState(() {
      _messages.removeWhere((m) => m.id == id);
      _searchMessages.removeWhere((m) => m.id == id);
      _replyTargets.remove(id);
    });
    unawaited(_persistMessages());
  }

  void _connectionChanged() {
    if (mounted && _foreground && _chatService.connected.value) {
      unawaited(_chatService.retryAttachmentCleanup());
      unawaited(_loadMessagesWithReactions());
      unawaited(_loadBlockState());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _lastTypedAt = null;
      unawaited(_audioPlayer.pause());
    }
    _updateChatActivity();
    if (!_foreground && _recording) unawaited(_cancelVoiceRecording());
    if (_foreground) {
      unawaited(_chatService.retryAttachmentCleanup());
      unawaited(_loadMessagesWithReactions());
      unawaited(_loadBlockState());
    }
  }

  Future<void> _loadMessagesWithReactions({bool older = false}) async {
    if (_loadingPage || (older && !_hasMore)) return;
    _loadingPage = true;
    final known = {
      for (final message in _messages) message.id: message.delivery,
    };
    if (mounted) setState(() => _loadError = null);
    try {
      final sent = _messages
          .where((m) => m.delivery == MessageDelivery.sent)
          .toList();
      final page = await _chatService.fetchConversation(
        widget.friend.id,
        before: older && sent.isNotEmpty ? sent.first : null,
        strict: true,
      );
      if (!mounted) return;
      setState(() {
        _firstUnreadId ??= page
            .where((m) => m.senderId == widget.friend.id && !m.isRead)
            .firstOrNull
            ?.id;
        if (older) {
          _messages = _merge(_messages, page);
          _hasMore = page.length == 60;
        } else {
          // A refresh reconciles deletions in the latest window but keeps older pages and pending sends.
          final first = page.firstOrNull;
          final keep = _messages.where(
            (m) =>
                m.delivery != MessageDelivery.sent ||
                known[m.id] != MessageDelivery.sent ||
                (first != null && m.createdAt.isBefore(first.createdAt)),
          );
          _messages = _merge(keep, page);
          if (sent.isEmpty) _hasMore = page.length == 60;
        }
        _isLoading = false;
      });
      unawaited(_persistMessages());
      final targets = await _chatService.fetchReplyTargets(page);
      if (!mounted) return;
      setState(() => _replyTargets.addAll(targets));
      if (_foreground && !_showScrollToBottom) {
        await _markVisibleRead();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadError = error is ChatServiceException
              ? error.message
              : 'Не удалось обновить переписку';
          _isLoading = false;
        });
      }
    } finally {
      _loadingPage = false;
      if (mounted) setState(() {});
    }
  }

  void _searchChanged(String value) {
    _searchTimer?.cancel();
    final generation = ++_searchGeneration;
    setState(() {
      _query = value.trim();
      _searchMessages = [];
      _searchBusy = _query.isNotEmpty;
      _searchMore = false;
      _loadError = null;
    });
    if (_query.isEmpty) return;
    _searchTimer = Timer(
      const Duration(milliseconds: 300),
      () => _search(generation),
    );
  }

  Future<void> _search(int generation, {bool older = false}) async {
    final query = _query;
    try {
      final page = await _chatService.fetchConversation(
        widget.friend.id,
        search: query,
        before: older && _searchMessages.isNotEmpty
            ? _searchMessages.first
            : null,
        strict: true,
      );
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searchMessages = older ? _merge(_searchMessages, page) : page;
        _loadError = null;
        _searchBusy = false;
        _searchMore = page.length == 60;
      });
    } catch (_) {
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _searchBusy = false;
          _loadError = 'Не удалось выполнить поиск. Повторите запрос.';
        });
      }
    }
  }

  void _subscribeRealtime() {
    _listener = (ChatMessage message) {
      final me = _chatService.userId;
      final involvesThisChat =
          (message.senderId == widget.friend.id && message.receiverId == me) ||
          (message.senderId == me && message.receiverId == widget.friend.id);
      if (!involvesThisChat || !mounted) return;

      final wasPresent = _messages.any((m) => m.id == message.id);

      setState(() {
        final index = _messages.indexWhere((m) => m.id == message.id);
        if (index >= 0) {
          _messages[index] = message;
        } else {
          _messages.add(message);
        }
        if (_query.isNotEmpty) {
          _searchMessages.removeWhere((m) => m.id == message.id);
          if (message.body?.toLowerCase().contains(_query.toLowerCase()) ??
              false) {
            _searchMessages = _merge(_searchMessages, [message]);
          }
        }
        _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      });

      if (_foreground &&
          !_showScrollToBottom &&
          message.senderId == widget.friend.id &&
          !message.isRead) {
        unawaited(_markVisibleRead());
      }
      unawaited(_persistMessages());
      if (!wasPresent && _query.isEmpty) {
        if (!_showScrollToBottom || message.senderId == me) {
          _scrollToBottom();
        } else {
          setState(() => _newMessages++);
        }
      }
      if (message.replyToId != null && _replyTarget(message) == null) {
        unawaited(
          _chatService.fetchReplyTargets([message]).then((targets) {
            if (mounted && targets.isNotEmpty) {
              setState(() => _replyTargets.addAll(targets));
            }
          }),
        );
      }
    };

    final listener = _listener;
    if (listener != null) _chatService.subscribe(listener);
  }

  /// Добавляет или удаляет реакцию у сообщения.
  Future<void> _toggleReaction(
    String messageId, {
    required bool add,
    String emoji = '👍',
  }) async {
    final ok = await _chatService.toggleReaction(messageId, emoji, add);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить реакцию')),
      );
      return;
    }
    // The service delivers the changed message to subscribers without replacing history.
  }

  /// Воспроизведение голосового сообщения (по URL из Storage).
  Future<void> _playVoice(ChatMessage message) async {
    if (_playingMessageId == message.id) {
      await _audioPlayer.stop();
      if (!mounted) return;
      setState(() => _playingMessageId = null);
      return;
    }
    try {
      final fresh = message.delivery == MessageDelivery.sent
          ? await _chatService.refreshAttachment(message)
          : message;
      final source = fresh?.audioUrl;
      if (source == null || source.startsWith('chat:')) {
        throw StateError('Вложение недоступно');
      }
      await _audioPlayer.play(
        source.startsWith('http') || source.startsWith('blob:')
            ? UrlSource(source)
            : DeviceFileSource(source),
      );
      if (!mounted) return;
      setState(() => _playingMessageId = message.id);
      _playerStateSubscription?.cancel();
      _playerStateSubscription = _audioPlayer.onPlayerComplete.listen((_) {
        if (!mounted) return;
        setState(() => _playingMessageId = null);
        _playerStateSubscription?.cancel();
      });
    } catch (error) {
      debugPrint('[Chat] play failed: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось воспроизвести. Нажмите ещё раз для повтора.',
          ),
        ),
      );
      setState(() => _playingMessageId = null);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      // ИСПРАВЛЕНО: при reverse: true низ переписки — это minScrollExtent
      // (offset 0), а не maxScrollExtent (начало, старые сообщения).
      _scrollController.jumpTo(_scrollController.position.minScrollExtent);
    });
  }

  Future<void> _send({String? sticker}) async {
    final text = _inputController.text.trim();
    if (sticker == null && text.isEmpty) return;
    _lastTypedAt = null;
    _updateChatActivity();
    await _sendMessage(text: sticker == null ? text : null, sticker: sticker);
  }

  Future<void> _sendPhoto({ImageSource source = ImageSource.gallery}) async {
    await _prepareMedia(() => _pickPhotos(source));
  }

  Future<List<ChatMediaDraft>> _pickPhotos(ImageSource source) async {
    final files = source == ImageSource.gallery
        ? await _picker.pickMultiImage(
            maxWidth: 2048,
            maxHeight: 2048,
            imageQuality: 85,
            limit: ChatMediaDraft.maxItems,
            requestFullMetadata: false,
          )
        : [
            await _picker.pickImage(
              source: source,
              maxWidth: 2048,
              maxHeight: 2048,
              imageQuality: 85,
              requestFullMetadata: false,
            ),
          ].whereType<XFile>().toList();
    final items = <ChatMediaDraft>[];
    for (final file in files) {
      items.add(
        ChatMediaDraft(file: file, isVideo: false, size: await file.length()),
      );
    }
    return items;
  }

  Future<List<ChatMediaDraft>> _pickVideo() async {
    final file = await _picker.pickVideo(source: ImageSource.gallery);
    return file == null
        ? []
        : [
            ChatMediaDraft(
              file: file,
              isVideo: true,
              size: await file.length(),
            ),
          ];
  }

  Future<void> _prepareMedia(
    Future<List<ChatMediaDraft>> Function() pick,
  ) async {
    if (_mediaBusy || _blockedByMe || _blockedByThem) return;
    final owner = _chatService.userId;
    if (owner == null) {
      _showError('Войдите в аккаунт');
      return;
    }
    setState(() => _mediaBusy = true);
    try {
      final initial = await pick();
      if (!mounted || _chatService.userId != owner || initial.isEmpty) return;
      final validation = ChatMediaDraft.validateBatch(initial);
      if (validation != null) {
        _showError(validation);
        return;
      }
      final selected = await Navigator.push<List<ChatMediaDraft>>(
        context,
        MaterialPageRoute(
          builder: (_) => ChatMediaComposer(
            items: initial,
            onAddPhotos: () => _pickPhotos(ImageSource.gallery),
            onAddVideo: _pickVideo,
          ),
        ),
      );
      if (!mounted || _chatService.userId != owner || selected == null) return;
      final error = ChatMediaDraft.validateBatch(selected);
      if (error != null) {
        _showError(error);
        return;
      }
      if (_blockedByMe || _blockedByThem) {
        _showError('Отправка сообщений заблокирована');
        return;
      }
      final pending = <ChatMessage>[];
      final now = DateTime.now().toUtc();
      _cancelMediaPreparation = false;
      var rejected = 0;
      for (final item in selected) {
        if (_cancelMediaPreparation ||
            !mounted ||
            _chatService.userId != owner) {
          break;
        }
        setState(
          () => _mediaProgress =
              'Сохраняем ${pending.length + rejected + 1} из ${selected.length}',
        );
        try {
          final id = newRideId();
          final path = await retainChatMedia(
            item.file,
            owner,
            id,
            item.extension,
            editedBytes: item.editedBytes,
          );
          if (!mounted || _chatService.userId != owner) return;
          final queued = ChatMessage(
            id: id,
            senderId: owner,
            receiverId: widget.friend.id,
            photoUrl: item.isVideo ? null : path,
            videoUrl: item.isVideo ? path : null,
            body: item.isVideo ? 'Видео' : null,
            createdAt: now.add(Duration(microseconds: pending.length)),
            replyToId: pending.isEmpty ? _replyingTo?.id : null,
            delivery: MessageDelivery.failed,
          );
          setState(() => _messages.add(queued));
          // No upload until the complete preparation stage has ended.
          await _persistMessages();
          VideoPreview? preview;
          String? posterPath;
          if (item.isVideo) {
            preview = await VideoPreviewService.inspect(path);
            if (preview.poster != null) {
              try {
                posterPath = await retainChatMedia(
                  item.file,
                  owner,
                  'poster-$id',
                  '.jpg',
                  editedBytes: preview.poster,
                );
              } catch (_) {
                /* The video remains sendable without a poster. */
              }
            }
          }
          if (!mounted || _chatService.userId != owner) return;
          pending.add(
            ChatMessage(
              id: id,
              senderId: owner,
              receiverId: widget.friend.id,
              photoUrl: item.isVideo ? null : path,
              videoUrl: item.isVideo ? path : null,
              videoPosterUrl: posterPath,
              videoMetadata: preview?.metadata,
              body: item.isVideo ? 'Видео' : null,
              createdAt: now.add(Duration(microseconds: pending.length)),
              replyToId: pending.isEmpty ? _replyingTo?.id : null,
              delivery: MessageDelivery.sending,
            ),
          );
          final prepared = pending.last;
          setState(
            () => _messages = _merge(_messages, [
              prepared.withDelivery(MessageDelivery.failed),
            ]),
          );
          await _persistMessages();
        } catch (_) {
          rejected++;
          if (!mounted || _chatService.userId != owner) return;
          _showError(
            'Один файл не удалось подготовить. Остальные сохранённые вложения доступны в чате.',
          );
        }
      }
      if (!mounted || _chatService.userId != owner) return;
      if (_cancelMediaPreparation) return;
      setState(() {
        _replyingTo = null;
        _mediaProgress = 'Отправляем ${pending.length} вложений';
      });
      // Save the entire selection before the first upload, for independent retries.
      try {
        await _persistMessages();
      } catch (_) {
        if (mounted) {
          final ids = pending.map((m) => m.id).toSet();
          setState(
            () => _messages = _messages
                .map(
                  (m) => ids.contains(m.id)
                      ? m.withDelivery(MessageDelivery.failed)
                      : m,
                )
                .toList(),
          );
          _showError(
            'Не удалось сохранить очередь. Освободите место на устройстве.',
          );
        }
        return;
      }
      _scrollToBottom();
      for (var index = 0; index < pending.length; index++) {
        if (!mounted || _chatService.userId != owner) return;
        setState(
          () => _mediaProgress = 'Отправляем ${index + 1} из ${pending.length}',
        );
        final sent = await _transmit(pending[index]);
        if (!sent) {
          if (!mounted) return;
          final waiting = pending.skip(index + 1).map((m) => m.id).toSet();
          setState(
            () => _messages = _messages
                .map(
                  (message) => waiting.contains(message.id)
                      ? message.withDelivery(MessageDelivery.failed)
                      : message,
                )
                .toList(),
          );
          await _persistMessages();
          break;
        }
      }
    } catch (_) {
      _showError(
        'Не удалось подготовить вложения. Попробуйте выбрать их снова.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _mediaBusy = false;
          _mediaProgress = null;
        });
      }
    }
  }

  /// Голосовое: нажатие на микрофон начинает запись, повторное — отправляет.
  Future<void> _toggleVoiceRecording() async {
    if (_recorderBusy) return;
    _recorderBusy = true;
    try {
      if (_recording) {
        _recordTicker?.cancel();
        _recordStopwatch.stop();
        final path = await _recorder.stop();
        final seconds = _recordStopwatch.elapsed.inSeconds.clamp(1, 600);
        if (!mounted) return;
        setState(() => _recording = false);
        _lastTypedAt = null;
        _updateChatActivity();
        if (path != null) {
          await _sendMessage(audioPath: path, audioSeconds: seconds);
        }
        return;
      }
      if (!await _recorder.hasPermission()) {
        _showError('Нет доступа к микрофону');
        return;
      }
      if (!mounted || !_foreground) return;
      final filename = 'voice_${newRideId()}.m4a';
      final path = kIsWeb
          ? filename
          : '${(await getTemporaryDirectory()).path}/$filename';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      if (!mounted || !_foreground) {
        await _recorder.stop();
        return;
      }
      _recordStopwatch
        ..reset()
        ..start();
      _recordTicker?.cancel();
      _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        if (_recordStopwatch.elapsed.inSeconds >= 600) {
          unawaited(_toggleVoiceRecording());
        }
      });
      setState(() => _recording = true);
      _updateChatActivity();
    } catch (error) {
      _recordTicker?.cancel();
      _recordStopwatch.stop();
      if (mounted) setState(() => _recording = false);
      _updateChatActivity();
      _showError(
        'Не удалось записать голосовое. Проверьте доступ к микрофону.',
      );
    } finally {
      _recorderBusy = false;
    }
  }

  Future<void> _cancelVoiceRecording() async {
    _recordTicker?.cancel();
    _recordStopwatch.stop();
    try {
      await _recorder.stop();
    } catch (error) {
      debugPrint('[Chat] cancel recording: $error');
    }
    if (mounted) setState(() => _recording = false);
    _lastTypedAt = null;
    _updateChatActivity();
  }

  /// Общая отправка: текст, стикер, фото или голосовое.
  Future<void> _sendMessage({
    SharedRoute? routeAttachment,
    String? text,
    String? sticker,
    String? photoPath,
    String? audioPath,
    int? audioSeconds,
  }) async {
    if ((text ?? '').isEmpty &&
        (sticker ?? '').isEmpty &&
        photoPath == null &&
        audioPath == null &&
        routeAttachment == null) {
      return;
    }

    if (_blockedByMe || _blockedByThem) {
      _showError('Отправка сообщений заблокирована');
      return;
    }
    final me = _chatService.userId;
    if (me == null) {
      _showError('Войдите в аккаунт');
      return;
    }
    if ((text?.length ?? 0) > 4000) {
      _showError('Максимум 4000 символов');
      return;
    }
    final messageId = newRideId();
    String? retainedAudio = audioPath;
    if (audioPath != null) {
      try {
        retainedAudio = await retainChatMedia(
          XFile(audioPath),
          me,
          messageId,
          '.m4a',
        );
      } catch (_) {
        _showError(
          'Не удалось сохранить голосовое. Освободите место и повторите.',
        );
        return;
      }
      if (!mounted || _chatService.userId != me) return;
    }
    final pending = ChatMessage(
      id: messageId,
      senderId: me,
      receiverId: widget.friend.id,
      body: text,
      sticker: sticker,
      photoUrl: photoPath,
      audioUrl: retainedAudio,
      audioSeconds: audioSeconds,
      replyToId: _replyingTo?.id,
      createdAt: DateTime.now().toUtc(),
      delivery: MessageDelivery.sending,
      routeAttachment: routeAttachment,
    );
    setState(() {
      _messages.add(pending);
      if (text != null) _inputController.clear();
      _stickerPanelOpen = false;
      _replyingTo = null;
    });
    try {
      await _persistMessages();
    } catch (_) {
      if (mounted) {
        setState(
          () => _messages = _messages
              .map(
                (m) => m.id == pending.id
                    ? m.withDelivery(MessageDelivery.failed)
                    : m,
              )
              .toList(),
        );
        _showError(
          'Не удалось сохранить очередь. Освободите место на устройстве.',
        );
      }
      return;
    }
    if (!mounted || _chatService.userId != me) return;
    _scrollToBottom();
    await _transmit(pending);
  }

  Future<void> _loadBlockState() async {
    try {
      final state = await _chatService.blockState(widget.friend.id);
      if (mounted) {
        setState(() {
          _blockedByMe = state.byMe;
          _blockedByThem = state.byThem;
        });
        _updateChatActivity();
      }
    } catch (_) {
      /* Server policies still enforce blocking while offline. */
    }
  }

  Future<void> _toggleBlock() async {
    final blocked = !_blockedByMe;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          blocked ? 'Заблокировать сообщения?' : 'Разблокировать сообщения?',
        ),
        content: Text(
          blocked
              ? 'Новые сообщения в обе стороны будут запрещены. История останется доступна.'
              : 'Вы снова сможете обмениваться сообщениями, если собеседник вас не заблокировал.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Подтвердить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _chatService.setBlocked(widget.friend.id, blocked);
      await _loadBlockState();
    } catch (error) {
      _showError(
        error is ChatServiceException
            ? error.message
            : 'Не удалось изменить блокировку',
      );
    }
  }

  void _showError(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<bool> _transmit(ChatMessage pending, {bool retry = false}) async {
    if (!mounted ||
        _chatService.userId != pending.senderId ||
        (retry && _mediaBusy)) {
      return false;
    }
    setState(() {
      final index = _messages.indexWhere((m) => m.id == pending.id);
      if (index >= 0) {
        _messages[index] = pending.withDelivery(MessageDelivery.sending);
      }
    });
    try {
      final saved = await _chatService.sendMessage(
        widget.friend.id,
        messageId: pending.id,
        retry: retry,
        text: pending.body,
        sticker: pending.sticker,
        photoPath: pending.photoUrl,
        videoPath: pending.videoUrl,
        videoPosterPath: pending.videoPosterUrl,
        videoMetadata: pending.videoMetadata,
        audioPath: pending.audioUrl,
        audioSeconds: pending.audioSeconds,
        replyToId: pending.replyToId,
        routeAttachment: pending.routeAttachment,
      );
      if (saved == null) {
        throw const ChatServiceException('Сервер не подтвердил отправку');
      }
      if (!mounted || _chatService.userId != pending.senderId) return false;
      setState(() => _messages = _merge(_messages, [saved]));
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        final index = _messages.indexWhere((m) => m.id == pending.id);
        if (index >= 0 && _messages[index].delivery != MessageDelivery.sent) {
          _messages[index] = pending.withDelivery(MessageDelivery.failed);
        }
      });
      _showError(
        error is ChatServiceException
            ? error.message
            : 'Не удалось отправить. Нажмите на сообщение, чтобы повторить.',
      );
      return false;
    } finally {
      try {
        await _persistMessages();
      } catch (_) {
        _showError(
          'Не удалось сохранить очередь. Освободите место на устройстве.',
        );
      }
    }
  }

  Future<void> _refreshAttachment(ChatMessage message) async {
    try {
      final fresh = await _chatService.refreshAttachment(message);
      if (fresh == null) {
        _showError('Сообщение больше недоступно');
        return;
      }
      if (mounted) setState(() => _messages = _merge(_messages, [fresh]));
    } catch (_) {
      _showError('Не удалось загрузить вложение');
    }
  }

  Future<void> _editMessage(ChatMessage message) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _EditMessageDialog(text: message.body ?? ''),
    );
    if (text == null || text == message.body || !mounted) return;
    try {
      final edited = await _chatService.editMessage(message.id, text);
      if (mounted) {
        setState(() {
          _messages = _merge(_messages, [edited]);
          _searchMessages = _merge(_searchMessages, [edited]);
        });
      }
      unawaited(_persistMessages());
    } catch (error) {
      _showError(
        error is ChatServiceException
            ? error.message
            : 'Не удалось изменить сообщение',
      );
    }
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  ChatMessage? _replyTarget(ChatMessage message) {
    for (final candidate in _messages) {
      if (candidate.id == message.replyToId) return candidate;
    }
    return _replyTargets[message.replyToId];
  }

  String _author(ChatMessage message) =>
      message.senderId == _chatService.userId ? 'Вы' : widget.friend.username;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Действия с перепиской',
            onSelected: (_) => _toggleBlock(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'block',
                child: Text(
                  _blockedByMe
                      ? 'Разблокировать сообщения'
                      : 'Заблокировать сообщения',
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: _searching ? 'Закрыть поиск' : 'Поиск в переписке',
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() => _searching = !_searching);
              if (!_searching) {
                _searchController.clear();
                _searchChanged('');
              }
            },
          ),
        ],
        titleSpacing: 0,
        title: GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PublicProfileScreen(
                userId: widget.friend.id,
                preloaded: widget.friend,
              ),
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                backgroundImage: _avatarImage(widget.friend.avatarUrl),
                child: _avatarImage(widget.friend.avatarUrl) == null
                    ? Text(
                        widget.friend.username.isEmpty
                            ? 'Р'
                            : widget.friend.username.characters.first
                                  .toUpperCase(),
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.friend.username,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17),
                    ),
                    ListenableBuilder(
                      listenable: PresenceService.instance,
                      builder: (_, __) => Text(
                        _blockedByMe || _blockedByThem
                            ? 'Не в сети'
                            : PresenceService.instance.chatStatus(
                                widget.friend.id,
                              ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          if (_searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: _searchChanged,
                decoration: const InputDecoration(
                  hintText: 'Поиск по всей переписке',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
          ValueListenableBuilder<bool>(
            valueListenable: _chatService.connected,
            builder: (context, connected, _) => connected
                ? const SizedBox.shrink()
                : const Padding(
                    padding: EdgeInsets.all(4),
                    child: Text(
                      'Подключение… История на устройстве доступна',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
          ),
          if (_loadError != null)
            MaterialBanner(
              content: Text(_loadError!),
              actions: [
                TextButton(
                  onPressed: () {
                    if (_query.isEmpty) {
                      _loadMessagesWithReactions();
                    } else {
                      _search(_searchGeneration);
                    }
                  },
                  child: const Text('Повторить'),
                ),
              ],
            ),
          if (_searchBusy) const LinearProgressIndicator(),
          Expanded(child: _buildMessages()),
          if (_stickerPanelOpen) _buildStickerPanel(),
          // Стрелка «в конец переписки» — появляется при отлистывании вверх.
          if (_showScrollToBottom)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 16, bottom: 4),
                child: FloatingActionButton.small(
                  heroTag: 'chat_scroll_down',
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.deepOrange,
                  elevation: 3,
                  onPressed: _scrollToBottom,
                  child: _newMessages > 0
                      ? Text('$_newMessages ↓')
                      : const Icon(Icons.arrow_downward),
                ),
              ),
            ),
          if (_blockedByMe || _blockedByThem)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Text(
                    _blockedByMe
                        ? 'Вы заблокировали сообщения'
                        : 'Собеседник ограничил сообщения',
                  ),
                  if (_blockedByMe)
                    TextButton(
                      onPressed: _toggleBlock,
                      child: const Text('Разблокировать'),
                    ),
                ],
              ),
            )
          else
            _buildInputBar(),
        ],
      ),
    );
  }

  ImageProvider? _avatarImage(String? url) {
    if (url == null ||
        !(url.startsWith('http://') || url.startsWith('https://'))) {
      return null;
    }
    return NetworkImage(url);
  }

  Widget _buildMessages() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_visibleMessages.isEmpty && _loadError != null) {
      return const Center(child: Text('История не загружена'));
    }
    if (_visibleMessages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 56,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            Text(
              _query.isEmpty ? 'Начните переписку' : 'Ничего не найдено',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _query.isEmpty
                  ? 'Скажите «поехали кататься» — или отправьте стикер 🚴'
                  : 'Попробуйте другое слово',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }

    // reverse: true — список сам держится у нижнего края, как в мессенджерах.
    // children собираются от НОВЫХ к старым (индекс 0 = низ списка).
    // Между днями вставляются разделители «Сегодня / Вчера / дата».
    final widgets = <Widget>[];

    final visible = _visibleMessages;
    for (var i = visible.length - 1; i >= 0; i--) {
      final message = visible[i];
      final day = _dateOnly(message.createdAt);
      // Группировка подряд идущих сообщений одного автора (телеграм-стиль):
      // сосед — сообщение рядом по списку от того же автора в пределах 2 мин
      // и того же дня.
      final newer = i + 1 < visible.length ? visible[i + 1] : null;
      final older = i > 0 ? visible[i - 1] : null;
      bool groupedWith(ChatMessage? other) =>
          other != null &&
          other.senderId == message.senderId &&
          _dateOnly(other.createdAt) == day &&
          other.createdAt.difference(message.createdAt).inMinutes.abs() < 2;
      widgets.add(
        _buildBubble(
          message,
          groupedWithNewer: groupedWith(newer),
          groupedWithOlder: groupedWith(older),
        ),
      );
      if (message.id == _firstUnreadId && _query.isEmpty) {
        widgets.add(
          const Center(
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Новые сообщения',
                style: TextStyle(color: Colors.deepOrange),
              ),
            ),
          ),
        );
      }
      if (older == null || _dateOnly(older.createdAt) != day) {
        widgets.add(_buildDateSeparator(message.createdAt));
      }
    }
    if (_query.isEmpty && _hasMore) {
      widgets.add(
        Center(
          child: TextButton(
            onPressed: _loadingPage
                ? null
                : () => _loadMessagesWithReactions(older: true),
            child: Text(_loadingPage ? 'Загружаем…' : 'Более ранние сообщения'),
          ),
        ),
      );
    }
    if (_query.isNotEmpty && _searchMore) {
      widgets.add(
        Center(
          child: TextButton(
            onPressed: () => _search(_searchGeneration, older: true),
            child: const Text('Ещё результаты'),
          ),
        ),
      );
    }
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      children: widgets,
    );
  }

  /// Локальная дата сообщения (без времени) — для разделителей дней.
  DateTime _dateOnly(DateTime utc) {
    final local = utc.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  /// Метка дня для разделителя: «Сегодня», «Вчера», «5 октября» (+ год,
  /// если не текущий).
  String _dateLabel(DateTime utc) {
    final local = utc.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Сегодня';
    if (diff == 1) return 'Вчера';
    const months = [
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ];
    final label = '${day.day} ${months[day.month - 1]}';
    return day.year == now.year ? label : '$label ${day.year}';
  }

  Widget _buildDateSeparator(DateTime utc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _dateLabel(utc),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBubble(
    ChatMessage message, {
    bool groupedWithNewer = false,
    bool groupedWithOlder = false,
  }) {
    final isMine = message.senderId == _chatService.userId;
    final align = isMine ? MainAxisAlignment.end : MainAxisAlignment.start;
    final colors = Theme.of(context).colorScheme;
    final bubbleColor = message.isStickerOnly
        ? Colors.transparent
        : isMine
        ? colors.primaryContainer
        : colors.surfaceContainerHigh;
    final textColor = isMine ? colors.onPrimaryContainer : colors.onSurface;
    final grouped = groupedWithNewer || groupedWithOlder;

    // «Хвостик» пузыря — у первого сообщения в цепочке (нет соседа-группы
    // снизу, т.е. со стороны старых). Внутри цепочки углы скруглены слабее.
    const big = Radius.circular(16);
    const small = Radius.circular(6);
    final topLeft = !isMine && !groupedWithOlder ? big : small;
    final topRight = isMine && !groupedWithOlder ? big : small;
    final bottomLeft = !isMine && !groupedWithNewer ? big : small;
    final bottomRight = isMine && !groupedWithNewer ? big : small;
    // Время и галочки — только на последнем (самом старом) сообщении цепочки.
    const showMeta = true;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: grouped ? 1.5 : 3),
      child: Row(
        mainAxisAlignment: align,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine) const SizedBox(width: 4),
          Flexible(
            child: SwipeToReply(
              key: ValueKey('reply_swipe_${message.id}'),
              enabled: message.delivery == MessageDelivery.sent,
              onReply: () {
                setState(() => _replyingTo = message);
                _inputFocus.requestFocus();
              },
              child: GestureDetector(
                onLongPress: () => _showMessageMenu(message),
                onTap: message.delivery == MessageDelivery.failed
                    ? () => _transmit(message, retry: true)
                    : null,
                child: Container(
                  padding: message.isStickerOnly
                      ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
                      : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.82,
                  ),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.only(
                      topLeft: topLeft,
                      topRight: topRight,
                      bottomLeft: bottomLeft,
                      bottomRight: bottomRight,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.replyToId != null) ...[
                        ChatReplyPreview(
                          message: _replyTarget(message),
                          author: _replyTarget(message) == null
                              ? 'Сообщение'
                              : _author(_replyTarget(message)!),
                        ),
                        const SizedBox(height: 6),
                      ],
                      if (message.groupInvitation != null)
                        GroupInvitationCard(message: message)
                      else if (message.routeAttachment != null)
                        SharedRouteCard(route: message.routeAttachment!)
                      else if (message.isStickerOnly)
                        Text(
                          message.sticker!,
                          style: const TextStyle(fontSize: 44),
                        )
                      else if (message.isVideo) ...[
                        SizedBox(
                          width: 220,
                          child: VideoPoster(
                            posterSource: message.videoPosterUrl,
                            metadata: message.videoMetadata,
                            localSource:
                                message.delivery != MessageDelivery.sent
                                ? message.videoUrl
                                : null,
                            onRetry: () => _refreshAttachment(message),
                            onTap: () {
                              unawaited(_audioPlayer.stop());
                              setState(() => _playingMessageId = null);
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ChatVideoPlayer(
                                    source: message.videoUrl!,
                                    autoPlay: true,
                                    onRefresh: () async =>
                                        (await _chatService.refreshAttachment(
                                          message,
                                        ))?.videoUrl,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ] else if (message.isPhoto) ...[
                        // Фото-сообщение; тап — просмотр на весь экран.
                        GestureDetector(
                          onTap: () => _showPhotoFullScreen(message),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: ChatPhoto(
                              source: message.photoUrl!,
                              onRetry: () => _refreshAttachment(message),
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                      ] else if (message.isVoice) ...[
                        // Голосовое: кнопка воспроизведения + длительность.
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: _playingMessageId == message.id
                                  ? 'Остановить голосовое'
                                  : 'Воспроизвести голосовое',
                              onPressed: () => _playVoice(message),
                              icon: Icon(
                                _playingMessageId == message.id
                                    ? Icons.stop_circle
                                    : Icons.play_circle_filled,
                                size: 32,
                                color: colors.primary,
                              ),
                            ),
                            SizedBox(
                              width: 105,
                              child: StreamBuilder<Duration>(
                                stream: _audioPlayer.onPositionChanged,
                                builder: (context, snapshot) {
                                  final total = (message.audioSeconds ?? 1)
                                      .clamp(1, 600);
                                  final position =
                                      _playingMessageId == message.id
                                      ? (snapshot.data?.inSeconds ?? 0).clamp(
                                          0,
                                          total,
                                        )
                                      : 0;
                                  return SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 3,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 5,
                                      ),
                                    ),
                                    child: Slider(
                                      value: position.toDouble(),
                                      max: total.toDouble(),
                                      activeColor: colors.primary,
                                      inactiveColor: colors.outlineVariant,
                                      onChanged: _playingMessageId == message.id
                                          ? (value) => _audioPlayer.seek(
                                              Duration(seconds: value.round()),
                                            )
                                          : null,
                                    ),
                                  );
                                },
                              ),
                            ),
                            Text(
                              '${(message.audioSeconds ?? 0) ~/ 60}:${((message.audioSeconds ?? 0) % 60).toString().padLeft(2, '0')}',
                              style: TextStyle(fontSize: 12, color: textColor),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                      ] else ...[
                        ChatMessageText(
                          text: message.body ?? '',
                          color: textColor,
                        ),
                        const SizedBox(height: 2),
                      ],
                      if (message.delivery == MessageDelivery.failed)
                        TextButton.icon(
                          onPressed: () => _transmit(message, retry: true),
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('Не отправлено · повторить'),
                        ),
                      if (showMeta)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (message.editedAt != null)
                              Text(
                                'изм. ',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: textColor,
                                ),
                              ),
                            Text(
                              _formatTime(message.createdAt),
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            if (isMine) ...[
                              const SizedBox(width: 3),
                              Icon(
                                message.delivery == MessageDelivery.failed
                                    ? Icons.error_outline
                                    : message.delivery ==
                                          MessageDelivery.sending
                                    ? Icons.schedule
                                    : message.isRead
                                    ? Icons.done_all
                                    : Icons.done,
                                size: 13,
                                color: message.isRead
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                              ),
                            ],
                          ],
                        ),
                      if (message.reactions.isNotEmpty)
                        Wrap(
                          spacing: 4,
                          children: message.reactions.entries
                              .map(
                                (entry) => _buildReactionBubble(
                                  message,
                                  entry.key,
                                  entry.value.length,
                                ),
                              )
                              .toList(),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (isMine) const SizedBox(width: 4),
        ],
      ),
    );
  }

  /// Пузырь с реакцией.
  Widget _buildReactionBubble(ChatMessage message, String emoji, int count) {
    return GestureDetector(
      onTap: () => _toggleReaction(
        message.id,
        add:
            !(message.reactions[emoji]?.contains(_chatService.userId) ?? false),
        emoji: emoji,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color:
              (message.reactions[emoji]?.contains(_chatService.userId) ?? false)
              ? Theme.of(context).colorScheme.secondaryContainer
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 4,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              emoji,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 4),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Контекстное меню сообщения (длинное нажатие): копировать текст,
  /// удалить своё. Фото открывается по тапу на весь экран.
  Future<void> _showMessageMenu(ChatMessage message) async {
    if (_mediaBusy && message.delivery != MessageDelivery.sent) return;
    final isMine = message.senderId == _chatService.userId;
    final canCopy = (message.body ?? '').trim().isNotEmpty;
    final canDelete = isMine && message.delivery == MessageDelivery.sent;
    final canReact = message.delivery == MessageDelivery.sent;
    if (message.delivery == MessageDelivery.sending) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.delivery == MessageDelivery.failed) ...[
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Повторить отправку'),
                onTap: () => Navigator.pop(sheetContext, 'retry'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Убрать неотправленное'),
                onTap: () => Navigator.pop(sheetContext, 'discard'),
              ),
            ],
            if (canDelete && canCopy && message.groupInvitation == null)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Изменить'),
                onTap: () => Navigator.pop(sheetContext, 'edit'),
              ),
            if (canReact)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  children: ['👍', '❤️', '😂', '🔥', '😮', '😢']
                      .map(
                        (emoji) => InkWell(
                          onTap: () =>
                              Navigator.pop(sheetContext, 'reaction:$emoji'),
                          child: Padding(
                            padding: const EdgeInsets.all(5),
                            child: Text(
                              emoji,
                              style: const TextStyle(fontSize: 27),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            if (canReact)
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Ответить'),
                onTap: () => Navigator.pop(sheetContext, 'reply'),
              ),
            if (canCopy)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Копировать'),
                onTap: () => Navigator.pop(sheetContext, 'copy'),
              ),
            if (canDelete)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text(
                  'Удалить',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () => Navigator.pop(sheetContext, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'retry') {
      await _transmit(message, retry: true);
      return;
    }
    if (action == 'discard') {
      try {
        await _chatService.queueDiscardedAttachment(message);
        if (!mounted || message.senderId != _chatService.userId) return;
        setState(() => _messages.removeWhere((m) => m.id == message.id));
        await _persistMessages();
        unawaited(_chatService.retryAttachmentCleanup());
      } catch (_) {
        if (mounted) setState(() => _messages = _merge(_messages, [message]));
        _showError('Не удалось сохранить удаление. Попробуйте ещё раз.');
      }
      return;
    }
    if (action == 'edit') {
      await _editMessage(message);
      return;
    }
    if (action == 'reply') {
      setState(() => _replyingTo = message);
      _inputFocus.requestFocus();
      return;
    }
    if (action.startsWith('reaction:')) {
      final emoji = action.substring('reaction:'.length);
      await _toggleReaction(
        message.id,
        add:
            !(message.reactions[emoji]?.contains(_chatService.userId) ?? false),
        emoji: emoji,
      );
      return;
    }
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.body ?? ''));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Скопировано')));
    } else if (action == 'delete') {
      // Оптимистично убираем; при ошибке сервера возвращаем на место.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Удалить сообщение у обоих?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Удалить'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final index = _messages.indexWhere((m) => m.id == message.id);
      setState(() {
        _messages.removeWhere((m) => m.id == message.id);
        _searchMessages.removeWhere((m) => m.id == message.id);
      });
      final ok = await _chatService.deleteMessage(message.id);
      if (!ok && mounted && index >= 0 && index <= _messages.length) {
        setState(() => _messages.insert(index, message));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось удалить сообщение')),
        );
      } else if (ok) {
        unawaited(_persistMessages());
        unawaited(_chatService.refreshUnread());
      }
    }
  }

  /// Просмотр фото сообщения на весь экран (тап по фото в пузыре).
  void _showPhotoFullScreen(ChatMessage message) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, __, ___) =>
            _PhotoViewerScreen(message: message, service: _chatService),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  Widget _buildStickerPanel() {
    final categories = ChatService.stickerCategories.keys.toList();
    final stickers =
        ChatService.stickerCategories[_stickerCategory] ??
        ChatService.stickerCategories.values.first;
    return Container(
      height: 230,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        children: [
          // Категории стикеров (как вкладки клавиатуры).
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: categories
                  .map(
                    (category) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(
                          category,
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: _stickerCategory == category,
                        selectedColor: Colors.deepOrange.withValues(alpha: 0.2),
                        labelStyle: TextStyle(
                          color: _stickerCategory == category
                              ? Colors.deepOrange
                              : Colors.black54,
                        ),
                        onSelected: (_) =>
                            setState(() => _stickerCategory = category),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 6,
                childAspectRatio: 1,
              ),
              itemCount: stickers.length,
              itemBuilder: (context, index) {
                final sticker = stickers[index];
                return InkWell(
                  onTap: () => _send(sticker: sticker),
                  borderRadius: BorderRadius.circular(12),
                  child: Center(
                    child: Text(sticker, style: const TextStyle(fontSize: 30)),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: Colors.grey.shade300)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_mediaProgress != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_mediaProgress!)),
                    if (_mediaProgress!.startsWith('Сохраняем'))
                      TextButton(
                        onPressed: () => setState(() {
                          _cancelMediaPreparation = true;
                          _mediaProgress = 'Останавливаем подготовку…';
                        }),
                        child: const Text('Остановить'),
                      ),
                  ],
                ),
              ),
            if (_replyingTo != null && !_recording)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 4, 6),
                child: ChatReplyPreview(
                  message: _replyingTo,
                  author: 'Ответ ${_author(_replyingTo!)}',
                  onCancel: () => setState(() => _replyingTo = null),
                ),
              ),
            if (_recording)
              Row(
                children: [
                  IconButton(
                    tooltip: 'Отменить запись',
                    onPressed: _cancelVoiceRecording,
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                  ),
                  const Icon(
                    Icons.fiber_manual_record,
                    color: Colors.red,
                    size: 14,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(_recordStopwatch.elapsed.inMinutes).toString().padLeft(2, '0')}:${(_recordStopwatch.elapsed.inSeconds % 60).toString().padLeft(2, '0')}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Идёт запись голосового…',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _toggleVoiceRecording,
                    icon: const Icon(Icons.send, size: 18),
                    label: const Text('Отправить'),
                  ),
                ],
              )
            else
              Row(
                children: [
                  IconButton(
                    tooltip: 'Стикеры',
                    icon: Icon(
                      Icons.emoji_emotions_outlined,
                      color: _stickerPanelOpen
                          ? Colors.deepOrange
                          : Colors.grey,
                    ),
                    onPressed: () {
                      _inputFocus.unfocus();
                      setState(() => _stickerPanelOpen = !_stickerPanelOpen);
                    },
                  ),
                  PopupMenuButton<String>(
                    enabled: !_mediaBusy,
                    tooltip: 'Вложение',
                    icon: const Icon(Icons.attach_file),
                    onSelected: (value) {
                      if (value == 'group') {
                        showGroupInvitationSheet(
                          context,
                          friend: widget.friend,
                        ).then((message) {
                          if (message != null && mounted) {
                            setState(
                              () => _messages = _merge(_messages, [message]),
                            );
                            unawaited(_persistMessages());
                            _scrollToBottom();
                          }
                        });
                      } else if (value == 'route') {
                        showLocalRoutePicker(context).then((route) {
                          if (route != null && mounted) {
                            _sendMessage(
                              text: '${route.label}: ${route.title}',
                              routeAttachment: route,
                            );
                          }
                        });
                      } else if (value == 'video') {
                        _prepareMedia(_pickVideo);
                      } else if (value == 'voice') {
                        _toggleVoiceRecording();
                      } else {
                        _sendPhoto(
                          source: value == 'camera'
                              ? ImageSource.camera
                              : ImageSource.gallery,
                        );
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'group',
                        child: ListTile(
                          leading: Icon(Icons.groups_2),
                          title: Text('Пригласить в совместный заезд'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'route',
                        child: ListTile(
                          leading: Icon(Icons.route),
                          title: Text('Заезд или маршрут'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'photo',
                        child: ListTile(
                          leading: Icon(Icons.photo_outlined),
                          title: Text('Фото из галереи (до 20)'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'video',
                        child: ListTile(
                          leading: Icon(Icons.video_library_outlined),
                          title: Text('Видео из галереи'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'camera',
                        child: ListTile(
                          leading: Icon(Icons.camera_alt_outlined),
                          title: Text('Сделать фото'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'voice',
                        child: ListTile(
                          leading: Icon(Icons.mic_none),
                          title: Text('Голосовое сообщение'),
                        ),
                      ),
                    ],
                  ),
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      onChanged: _composerChanged,
                      focusNode: _inputFocus,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      maxLength: 4000,
                      textInputAction: TextInputAction.newline,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: 'Сообщение',
                        counterText: '',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide(color: Colors.grey.shade300),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _inputController,
                    builder: (context, value, _) {
                      final hasText = value.text.trim().isNotEmpty;
                      return CircleAvatar(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        child: IconButton(
                          tooltip: hasText ? 'Отправить' : 'Записать голосовое',
                          icon: Icon(
                            hasText ? Icons.send : Icons.mic,
                            color: Theme.of(context).colorScheme.onPrimary,
                            size: 20,
                          ),
                          onPressed: hasText
                              ? () => _send()
                              : _toggleVoiceRecording,
                        ),
                      );
                    },
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Полноэкранный просмотр фото с зумом (тап — закрыть, кнопка — тоже).
class _PhotoViewerScreen extends StatefulWidget {
  const _PhotoViewerScreen({required this.message, required this.service});
  final ChatMessage message;
  final ChatService service;
  @override
  State<_PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<_PhotoViewerScreen> {
  late ChatMessage _message = widget.message;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
    ),
    body: Center(
      child: InteractiveViewer(
        maxScale: 5,
        child: ChatPhoto(
          source: _message.photoUrl!,
          fullScreen: true,
          onRetry: () async {
            final fresh = await widget.service.refreshAttachment(_message);
            if (fresh != null && mounted) setState(() => _message = fresh);
          },
        ),
      ),
    ),
  );
}

class _EditMessageDialog extends StatefulWidget {
  const _EditMessageDialog({required this.text});
  final String text;
  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final _controller = TextEditingController(text: widget.text);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Изменить сообщение'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      minLines: 1,
      maxLines: 5,
      maxLength: 4000,
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (_controller.text.trim().isNotEmpty) {
            Navigator.pop(context, _controller.text.trim());
          }
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
}
