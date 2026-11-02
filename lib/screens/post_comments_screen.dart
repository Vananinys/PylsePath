import 'package:flutter/material.dart';

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';

import '../models/community_post.dart';
import '../models/friend_profile.dart';
import '../models/post_comment.dart';
import '../services/community_service.dart';
import 'public_profile_screen.dart';
import '../services/moderation_service.dart';
import '../widgets/moderation_dialogs.dart';

/// Комментарии поста: ветки (ответ на комментарий), фото в комментарии,
/// удаление своих. Ввод внизу; кнопка ответа подставляет «Кому:».
class PostCommentsScreen extends StatefulWidget {
  final CommunityPost post;

  const PostCommentsScreen({super.key, required this.post, this.service});
  final CommunityService? service;

  @override
  State<PostCommentsScreen> createState() => _PostCommentsScreenState();
}

class _PostCommentsScreenState extends State<PostCommentsScreen> {
  late final CommunityService _communityService;
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();
  final FocusNode _inputFocus = FocusNode();
  late final String? _owner;
  int _loadGeneration = 0, _sendGeneration = 0, _photoGeneration = 0;
  bool _accountChanged = false;
  bool _current() {
    if (!mounted) return false;
    if (_communityService.userId != _owner) {
      if (!_accountChanged) setState(() => _accountChanged = true);
      return false;
    }
    return true;
  }

  bool get _hasInput =>
      _inputController.text.trim().isNotEmpty || _pendingPhotoPath != null;
  void _inputChanged() {
    if (mounted) setState(() {});
  }

  ModerationStatus _moderation = const ModerationStatus();
  RealtimeChannel? _moderationChannel;
  Timer? _moderationDebounce;
  Future<void> _loadModeration() async {
    try {
      final status = await ModerationService().status();
      if (!mounted || _communityService.userId != _owner) return;
      setState(() => _moderation = status);
      _moderationChannel ??= Supabase.instance.client
          .channel('comment-moderation-${identityHashCode(this)}')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'community_moderation_events',
            callback: (_) {
              _moderationDebounce?.cancel();
              _moderationDebounce = Timer(
                const Duration(milliseconds: 200),
                () {
                  if (mounted) unawaited(_load());
                },
              );
            },
          )
          .subscribe();
    } catch (_) {
      /* Server policies remain authoritative when offline. */
    }
  }

  List<PostComment> _comments = [];
  bool _isLoading = true;
  bool _sending = false;
  String? _busyCommentId;
  String? _loadError;

  /// На какой комментарий отвечаем (null — верхний уровень).
  PostComment? _replyTo;

  /// Локальное фото, прикреплённое к вводу (загружается при отправке).
  String? _pendingPhotoPath;

  @override
  void initState() {
    super.initState();
    _communityService = widget.service ?? CommunityService();
    _owner = _communityService.userId;
    _inputController.addListener(_inputChanged);
    _load();
  }

  @override
  void dispose() {
    _moderationDebounce?.cancel();
    final channel = _moderationChannel;
    if (channel != null)
      unawaited(Supabase.instance.client.removeChannel(channel));
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted || !_current()) return;
    final generation = ++_loadGeneration;
    unawaited(_loadModeration());
    try {
      final comments = await _communityService.fetchComments(
        widget.post.id,
        strict: true,
      );
      if (!mounted || !_current() || generation != _loadGeneration) return;
      setState(() {
        _comments = comments;
        _isLoading = false;
        _loadError = null;
      });
    } on CommunityServiceException catch (error) {
      if (mounted && _current() && generation == _loadGeneration)
        setState(() {
          _isLoading = false;
          _loadError = error.message;
        });
    } catch (_) {
      if (mounted && _current() && generation == _loadGeneration)
        setState(() {
          _isLoading = false;
          _loadError = 'Не удалось загрузить комментарии. Повторите попытку.';
        });
    }
  }

  Future<void> _pickPhoto() async {
    if (_sending || !_current()) return;
    final generation = ++_photoGeneration;
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
      if (picked == null ||
          !_current() ||
          generation != _photoGeneration ||
          _sending)
        return;
      setState(() => _pendingPhotoPath = picked.path);
    } catch (_) {
      if (!mounted || !_current() || generation != _photoGeneration || _sending)
        return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Не удалось выбрать фото')));
    }
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty && _pendingPhotoPath == null) return;
    if (_sending || !_current() || _moderation.isBanned) return;
    final generation = ++_sendGeneration;
    ++_photoGeneration;
    final photo = _pendingPhotoPath;
    final reply = _replyTo;

    setState(() => _sending = true);
    try {
      await _communityService.addComment(
        widget.post.id,
        body: text,
        parentCommentId: reply?.id,
        photoPath: photo,
        expectedOwner: _owner,
      );
      if (!mounted || !_current() || generation != _sendGeneration) return;
      _inputController.clear();
      setState(() {
        _replyTo = null;
        _pendingPhotoPath = null;
      });
      await _load();
      if (mounted && _current() && generation == _sendGeneration)
        _scrollToBottom();
    } on CommunityServiceException catch (error) {
      if (!mounted || !_current()) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (mounted && _current() && generation == _sendGeneration)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось отправить комментарий. Текст и вложение сохранены.',
            ),
          ),
        );
    } finally {
      if (mounted && _current() && generation == _sendGeneration)
        setState(() => _sending = false);
    }
  }

  Future<void> _deleteComment(PostComment comment) async {
    if (_busyCommentId != null || !_current()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить комментарий?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !_current()) return;
    setState(() => _busyCommentId = comment.id);
    try {
      await _communityService.deleteComment(comment.id);
      if (mounted && _current()) await _load();
    } on CommunityServiceException catch (error) {
      if (mounted && _current())
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted && _current()) setState(() => _busyCommentId = null);
    }
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)} ${two(local.hour)}:${two(local.minute)}';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _current() && _scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_accountChanged || _communityService.userId != _owner)
      return Scaffold(
        appBar: AppBar(title: const Text('Комментарии')),
        body: const Center(
          child: Text('Аккаунт изменился. Откройте комментарии заново.'),
        ),
      );
    final topLevel = _comments.where((comment) => !comment.isReply).toList();
    final me = _communityService.userId;

    return Scaffold(
      appBar: AppBar(title: const Text('Комментарии'), centerTitle: true),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_loadError != null && topLevel.isNotEmpty)
                  MaterialBanner(
                    content: Text(_loadError!),
                    actions: [
                      TextButton(
                        onPressed: _load,
                        child: const Text('Повторить'),
                      ),
                    ],
                  ),
                Expanded(
                  child: _loadError != null && topLevel.isEmpty
                      ? Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.cloud_off_outlined, size: 40),
                                const SizedBox(height: 12),
                                const Text(
                                  "Комментарии пока недоступны",
                                  textAlign: TextAlign.center,
                                ),
                                TextButton(
                                  onPressed: _load,
                                  child: const Text("Повторить загрузку"),
                                ),
                              ],
                            ),
                          ),
                        )
                      : topLevel.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.chat_bubble_outline,
                                size: 56,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Комментариев пока нет',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Будьте первым — напишите что-нибудь',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(12),
                            children: topLevel
                                .map(
                                  (comment) =>
                                      _buildCommentWithReplies(comment, me),
                                )
                                .toList(),
                          ),
                        ),
                ),
                if (_replyTo != null) _buildReplyingBar(),
                if (_pendingPhotoPath != null) _buildPendingPhotoBar(),
                if (_moderation.isBanned)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_moderation.banDescription),
                    ),
                  )
                else
                  _buildInputBar(),
              ],
            ),
    );
  }

  Widget _buildCommentWithReplies(PostComment comment, String? me) {
    final replies = _comments
        .where((c) => c.parentCommentId == comment.id)
        .toList();
    return Column(
      children: [
        _buildCommentTile(comment, me, isReply: false),
        // Ветки: ответы с отступом.
        for (final reply in replies)
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: _buildCommentTile(reply, me, isReply: true),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildCommentTile(
    PostComment comment,
    String? me, {
    required bool isReply,
  }) {
    final isMine = comment.authorId == me;
    final busy = _busyCommentId == comment.id;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PublicProfileScreen(
                userId: comment.authorId,
                preloaded: FriendProfile(
                  id: comment.authorId,
                  username: comment.authorName,
                  avatarUrl: comment.authorAvatarUrl,
                ),
              ),
            ),
          ),
          child: _buildAuthorAvatar(comment),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: isReply
                      ? Theme.of(context).colorScheme.surfaceContainerLow
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      comment.authorName,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (comment.body.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(comment.body, style: const TextStyle(fontSize: 14)),
                    ],
                    if (comment.photoUrl != null) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          comment.photoUrl!,
                          width: 180,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => SizedBox(
                            width: 180,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'Фото недоступно',
                                  textAlign: TextAlign.center,
                                ),
                                TextButton.icon(
                                  onPressed: () async {
                                    if (!_current()) return;
                                    await NetworkImage(comment.photoUrl!)
                                        .evict();
                                    if (_current()) await _load();
                                  },
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Повторить'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    _formatTime(comment.createdAt),
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Ответить — только на верхний уровень (одна ветка).
                  if (!isReply && !_moderation.isBanned)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: _sending
                          ? null
                          : () {
                              setState(() => _replyTo = comment);
                              _inputFocus.requestFocus();
                            },
                      child: const Text(
                        'Ответить',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  if (_moderation.isModerator && !busy)
                    IconButton(
                      tooltip: 'Модерация комментария',
                      icon: const Icon(Icons.shield_outlined, size: 18),
                      onPressed: () async {
                        final changed = await showPostModeration(
                          context,
                          contentId: comment.id,
                          authorId: comment.authorId,
                          authorName: comment.authorName,
                          kind: 'comment',
                        );
                        if (changed && mounted) await _load();
                      },
                    ),
                  if (isMine && !busy)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => _deleteComment(comment),
                      child: const Text(
                        'Удалить',
                        style: TextStyle(fontSize: 11, color: Colors.redAccent),
                      ),
                    ),
                  if (busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAuthorAvatar(PostComment comment) {
    final hasAvatar =
        comment.authorAvatarUrl != null &&
        (comment.authorAvatarUrl!.startsWith('http://') ||
            comment.authorAvatarUrl!.startsWith('https://'));
    if (hasAvatar) {
      return CircleAvatar(
        radius: 16,
        backgroundColor: Colors.deepOrange.shade50,
        backgroundImage: NetworkImage(comment.authorAvatarUrl!),
      );
    }
    return CircleAvatar(
      radius: 16,
      backgroundColor: Colors.deepOrange.shade50,
      child: Text(
        comment.authorName.isEmpty
            ? 'Р'
            : comment.authorName.characters.first.toUpperCase(),
        style: const TextStyle(
          color: Colors.deepOrange,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildReplyingBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.deepOrange.withValues(alpha: 0.08),
      child: Row(
        children: [
          const Icon(Icons.reply, size: 16, color: Colors.deepOrange),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Ответ ${_replyTo!.authorName}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          IconButton(
            tooltip: 'Отменить ответ',
            icon: const Icon(Icons.close, size: 16),
            onPressed: _sending ? null : () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingPhotoBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(
            Icons.image_outlined,
            size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Фото прикреплено',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Убрать вложение',
            icon: const Icon(Icons.close, size: 16),
            onPressed: _sending
                ? null
                : () => setState(() => _pendingPhotoPath = null),
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
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Прикрепить фото',
              icon: Icon(
                Icons.image_outlined,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              onPressed: _sending ? null : _pickPhoto,
            ),
            Expanded(
              child: TextField(
                enabled: !_sending,
                focusNode: _inputFocus,
                controller: _inputController,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: _replyTo == null
                      ? 'Комментарий...'
                      : 'Ваш ответ...',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            CircleAvatar(
              backgroundColor: Colors.deepOrange,
              child: IconButton(
                tooltip: 'Отправить комментарий',
                icon: const Icon(Icons.send, color: Colors.white, size: 20),
                onPressed: _sending || !_hasInput ? null : _send,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
