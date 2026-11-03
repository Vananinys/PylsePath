import '../data/community_draft_store.dart';
import 'community_composer_frame.dart';
// ignore: unused_import
import '../config/app_variant.dart';
import '../data/ui_snapshot_cache.dart';
import '../data/user_scope.dart';

import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/moderation_service.dart';
import '../screens/moderation_screen.dart';
import 'moderation_dialogs.dart';

import '../data/workout_history_repository.dart';
import '../models/community_post.dart';
import '../models/shared_route.dart';
import '../models/saved_route.dart';
import '../models/friend_profile.dart';
import '../services/community_service.dart';
import '../screens/post_comments_screen.dart';
import '../screens/public_profile_screen.dart';
import 'community_post_card.dart';
import 'community_post_edit_sheet.dart';
import 'community_activity_panel.dart';
import '../models/community_post_topic.dart';
import 'community_route_picker.dart';
import 'community_post_share_sheet.dart';
import '../services/community_route_choices.dart';
import '../screens/community_post_screen.dart';
import '../screens/workout_history_screen.dart';
import '../screens/notifications_screen.dart';
import '../services/notification_service.dart';
import '../utils/gpx_share.dart';
import '../services/ride_media_service.dart';
import 'ride_media_selection.dart';
import 'track_privacy_picker.dart';

Future<bool> showCommunityComposer(
  BuildContext context, {
  SavedRoute? route,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ComposerDialog(route: route),
    ) ??
    false;

/// Лента сообщества: композер «Что нового?» + карточки постов
/// (лайки, комментарии, фото, GPX прикреплённого заезда).
class CommunityFeed extends StatefulWidget {
  const CommunityFeed({super.key, this.onFindFriends});
  final VoidCallback? onFindFriends;

  @override
  State<CommunityFeed> createState() => _CommunityFeedState();
}

class _CommunityFeedState extends State<CommunityFeed>
    with WidgetsBindingObserver {
  final CommunityService _communityService = CommunityService();
  final String? _cacheOwner = UserScope.currentUserId();
  ModerationStatus _moderation = const ModerationStatus();
  RealtimeChannel? _moderationChannel;
  Timer? _moderationDebounce;

  Future<void> _loadModeration() async {
    try {
      final status = await ModerationService().status();
      if (!mounted || UserScope.currentUserId() != _cacheOwner) return;
      setState(() => _moderation = status);
      _moderationChannel ??= Supabase.instance.client
          .channel('community-moderation-${identityHashCode(this)}')
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
      /* Offline reads keep working; server checks every write. */
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _moderationDebounce?.cancel();
    final channel = _moderationChannel;
    if (channel != null)
      unawaited(Supabase.instance.client.removeChannel(channel));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) unawaited(_load());
  }

  bool _isLoading = true;
  bool _refreshing = false;
  String? _cacheNotice;
  String? _loadError;
  int _loadGeneration = 0;
  List<CommunityPost> _posts = [];
  static const _pageSize = 20;
  CommunityFeedScope _scope = CommunityFeedScope.everyone;
  final Set<String> _topics = {};
  CommunityPostType _type = CommunityPostType.all;
  bool _canLoadMore = false, _loadingMore = false;
  String? _pageError;
  final _pendingLikes = <String>{};
  String get _cacheName => 'community_feed_${_scope.name}_${_type.name}_${(_topics.toList()..sort()).join('_')}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    unawaited(_loadModeration());
    final generation = ++_loadGeneration;
    final owner = _cacheOwner;
    bool current() =>
        mounted &&
        generation == _loadGeneration &&
        UserScope.currentUserId() == owner;
    final scope = _scope;
    final cache = UiSnapshotCache(_cacheName, owner);
    if (_isLoading) {
      final rows = await cache.read();
      if (!current()) return;
      if (rows != null) {
        try {
          final posts = rows
              .map(CommunityPost.fromSnapshot)
              .where(
                (p) =>
                    p.audience == CommunityPostAudience.everyone &&
                    p.privatePhotoPaths.isEmpty && p.videoPath == null,
              )
              .toList();
          setState(() {
            _posts = posts;
            _isLoading = false;
            _cacheNotice = 'Сохранённая лента';
          });
        } catch (_) {
          /* Invalid snapshots are replaced by a network response. */
        }
      }
    }
    if (!current()) return;
    setState(() => _refreshing = true);
    try {
      final posts = await _communityService.fetchFeed(
        strict: true,
        limit: _pageSize,
        scope: scope,
        type: _type,
        topics: _topics.toList(),
      );
      if (!current()) return;
      setState(() {
        _posts = posts;
        _isLoading = false;
        _cacheNotice = null;
        _loadError = null;
        _canLoadMore = posts.length == _pageSize;
        _loadingMore = false;
        _pageError = null;
      });
      await _persistDisplayedPosts();
      if (!current()) return;
      final counts = await _communityService.commentsCount(
        posts.map((post) => post.id).toList(),
      );
      if (!current()) return;
      setState(() {
        _posts = _posts
            .map(
              (post) => post.copyWith(
                commentsCount: counts[post.id] ?? post.commentsCount,
              ),
            )
            .toList();
      });
      await _persistDisplayedPosts();
    } catch (_) {
      if (!current()) return;
      setState(() {
        _isLoading = false;
        _loadingMore = false;
        _canLoadMore = false;
        _loadError = 'Не удалось загрузить публикации. Проверьте подключение и повторите.';
        _cacheNotice = _posts.isEmpty
            ? 'Не удалось обновить ленту. Потяните вниз, чтобы повторить.'
            : 'Сохранённая лента · не удалось обновить';
      });
    } finally {
      if (current()) setState(() => _refreshing = false);
    }
  }

  Future<void> _persistDisplayedPosts() async {
    final owner = _cacheOwner;
    if (UserScope.currentUserId() != owner) return;
    await UiSnapshotCache(_cacheName, owner).write(
      _posts
          .where(
            (p) =>
                p.audience == CommunityPostAudience.everyone &&
                p.privatePhotoPaths.isEmpty && p.videoPath == null,
          )
          .take(100)
          .map((post) => post.toSnapshot())
          .toList(),
    );
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _refreshing || !_canLoadMore || _posts.isEmpty) return;
    final generation = _loadGeneration;
    final cursor = _posts.last;
    final scope = _scope;
    setState(() {
      _loadingMore = true;
      _pageError = null;
    });
    bool current() =>
        mounted &&
        generation == _loadGeneration &&
        UserScope.currentUserId() == _cacheOwner;
    try {
      final page = await _communityService.fetchFeed(
        strict: true,
        limit: _pageSize,
        scope: scope,
        type: _type,
        topics: _topics.toList(),
        before: cursor.createdAt,
        beforeId: cursor.id,
      );
      if (!current()) return;
      final counts = await _communityService.commentsCount(
        page.map((p) => p.id).toList(),
      );
      if (!current()) return;
      final ids = _posts.map((p) => p.id).toSet();
      setState(() {
        _posts.addAll(
          page
              .where((p) => ids.add(p.id))
              .map(
                (p) =>
                    p.copyWith(commentsCount: counts[p.id] ?? p.commentsCount),
              ),
        );
        _canLoadMore = page.length == _pageSize;
      });
      await _persistDisplayedPosts();
    } catch (_) {
      if (current()) {
        setState(() => _pageError = 'Не удалось загрузить следующие посты');
      }
    } finally {
      if (current()) setState(() => _loadingMore = false);
    }
  }

  void _changeScope(CommunityFeedScope scope) {
    if (_scope == scope) return;
    setState(() {
      _scope = scope;
      _posts = [];
      _isLoading = true;
      _canLoadMore = false;
      _pageError = null;
      _cacheNotice = null;
      _loadError = null;
      _loadingMore = false;
    });
    _load();
  }

  void _changeType(CommunityPostType type) {
    if (_type == type) return;
    setState(() {
      _type = type;
      _posts = [];
      _isLoading = true;
      _canLoadMore = false;
      _loadingMore = false;
      _pageError = null;
      _cacheNotice = null;
      _loadError = null;
    });
    _load();
  }

  Future<void> _editPost(CommunityPost post) async {
    final changed = await showCommunityPostEditor(context,
      post: post,
      currentUserId: () => _communityService.userId,
      onSave: (body) => _communityService.updatePostBody(post.id, body,
        expectedOwner: _cacheOwner),
    );
    if (changed && mounted) await _load();
  }

  Future<void> _openComposer() async {
    if (await showCommunityComposer(context) && mounted) await _load();
  }

  Future<void> _toggleLike(CommunityPost post) async {
    final index = _posts.indexWhere((p) => p.id == post.id);
    if (index == -1 || !_pendingLikes.add(post.id)) return;
    final generation = _loadGeneration;
    // Optimistic: мгновенно меняем лайк, сервер — фоном.
    final updated = post.copyWith(
      likedByMe: !post.likedByMe,
      likeCount: post.likeCount + (post.likedByMe ? -1 : 1),
    );
    setState(() => _posts[index] = updated);
    try {
      await _communityService.toggleLike(post.id, isLiked: post.likedByMe);
      if (mounted && generation == _loadGeneration) {
        await _persistDisplayedPosts();
      }
    } on CommunityServiceException catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      // Откат при ошибке.
      final currentIndex = _posts.indexWhere((p) => p.id == post.id);
      if (currentIndex >= 0) setState(() => _posts[currentIndex] = post);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      _pendingLikes.remove(post.id);
    }
  }

  Future<void> _deletePost(CommunityPost post) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить пост?'),
        content: const Text('Пост будет удалён из ленты сообщества.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Закрыть'),
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

    try {
      await _communityService.deletePost(post.id);
      if (!mounted || UserScope.currentUserId() != _cacheOwner) return;
      setState(() => _posts.removeWhere((p) => p.id == post.id));
      await _persistDisplayedPosts();
    } on CommunityServiceException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _openComments(CommunityPost post) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => PostCommentsScreen(post: post)),
    );
    // Пересчитать счётчик комментариев после возврата.
    final counts = await _communityService.commentsCount([post.id]);
    if (!mounted) return;
    final index = _posts.indexWhere((p) => p.id == post.id);
    if (index != -1) {
      setState(
        () => _posts[index] = _posts[index].copyWith(
          commentsCount: counts[post.id] ?? 0,
        ),
      );
    }
  }

  Future<void> _downloadGpx(CommunityPost post) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final attachment = post.routeAttachment;
      if (attachment != null && attachment.points.length >= 2) {
        await GpxShare.route(context, attachment.toSavedRoute());
        return;
      }
      final gpx = post.shareGpx && post.rideId != null
          ? await _communityService.fetchRideGpx(post.rideId!)
          : null;
      if (!mounted) return;
      if (gpx == null) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Трек недоступен: автор не разрешил скачивание'),
          ),
        );
        return;
      }
      await GpxShare.text(context, gpx, 'PulsePath_${post.id}');
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Не удалось подготовить GPX. Повторите попытку.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: _load,
    child: CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CommunityActivityPanel(
                  refreshToken: _loadGeneration,
                  onOpenHistory: () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => const WorkoutHistoryScreen(),
                  )),
                  onOpenFriends: widget.onFindFriends,
                  onOpenPost: (post) async {
                    await Navigator.push(context, MaterialPageRoute(
                      builder: (_) => CommunityPostScreen(postId: post.id),
                    ));
                    if (mounted) await _load();
                  },
                ),
                Align(alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(
                      builder: (_) => const NotificationsScreen(),
                    )),
                    icon: const Icon(Icons.notifications_outlined),
                    label: ValueListenableBuilder<int>(
                      valueListenable: NotificationService.badge,
                      builder: (_, count, _) => Text(count == 0
                          ? 'Уведомления' : 'Уведомления · $count'),
                    ),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final scope in CommunityFeedScope.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(switch (scope) {
                              CommunityFeedScope.everyone => 'Все публикации',
                              CommunityFeedScope.friends => 'От друзей',
                              CommunityFeedScope.mine => 'Мои посты',
                            }),
                            selected: scope == _scope,
                            onSelected: (_) => _changeScope(scope),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final type in CommunityPostType.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(switch (type) {
                            CommunityPostType.all => 'Все форматы',
                            CommunityPostType.text => 'Текст',
                            CommunityPostType.photos => 'Фото',
                            CommunityPostType.videos => 'Видео',
                            CommunityPostType.rides => 'Заезды',
                          }),
                          selected: type == _type,
                          onSelected: (_) => _changeType(type),
                        ),
                      ),
                  ]),
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final topic in CommunityPostTopic.values)
                    FilterChip(label: ConstrainedBox(constraints: BoxConstraints(maxWidth: (MediaQuery.sizeOf(context).width - 80).clamp(90, 400).toDouble()), child: Text(topic.label, softWrap: true, maxLines: 4, overflow: TextOverflow.visible)), selected: _topics.contains(topic.id),
                      onSelected: (selected) {
                        setState(() { selected ? _topics.add(topic.id) : _topics.remove(topic.id); _posts = []; _isLoading = true; _loadingMore = false; _canLoadMore = false; });
                        _load();
                      }),
                ]),
                if (_moderation.isModerator)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.shield_outlined),
                    title: const Text('Модерация сообщества'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ModerationScreen(),
                        ),
                      );
                      if (mounted) await _load();
                    },
                  ),
                if (_moderation.isBanned)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(_moderation.banDescription),
                  ),
                FilledButton.icon(
                  onPressed: _moderation.isBanned ? null : _openComposer,
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Создать публикацию'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    alignment: Alignment.centerLeft,
                  ),
                ),
                const SizedBox(height: 12),
                if (_refreshing) const LinearProgressIndicator(),
                if (_cacheNotice != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      _cacheNotice!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (_isLoading)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_posts.isEmpty && _loadError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        const Icon(Icons.cloud_off_outlined, size: 40),
                        const SizedBox(height: 12),
                        Text(_loadError!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Повторить'),
                        ),
                      ],
                    ),
                  )
                else if (_posts.isEmpty)
                  _buildEmptyState(),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.builder(
            itemCount: _posts.length,
            itemBuilder: (context, index) {
              final post = _posts[index];
              return CommunityPostCard(
                key: ValueKey(post.id),
                post: post,
                currentUserId: _communityService.userId,
                onShare: () => showCommunityPostShare(context, post: post),
                onRefreshVideoUrl: post.videoPath == null ? null : () async =>
                    (await _communityService.resolvePostMedia(post, expectedOwner: _cacheOwner)).videoUrl,
                onLike: _moderation.isBanned || _pendingLikes.contains(post.id)
                    ? null
                    : () => _toggleLike(post),
                onRefreshPhotoUrls: post.privatePhotoPaths.isEmpty
                    ? null
                    : () async => (await _communityService.resolvePostMedia(
                        post,
                        expectedOwner: _cacheOwner,
                      )).photoUrls,
                onModerate: _moderation.isModerator
                    ? () async {
                        final changed = await showPostModeration(
                          context,
                          contentId: post.id,
                          authorId: post.authorId,
                          authorName: post.authorName,
                        );
                        if (changed && mounted) await _load();
                      }
                    : null,
                onAuthorTap: () => _openAuthorProfile(post),
                onEdit: !_moderation.isBanned && post.authorId == _communityService.userId
                    ? () => _editPost(post)
                    : null,
                onDelete: post.authorId == _communityService.userId
                    ? () => _deletePost(post)
                    : null,
                onOpenComments: () => _openComments(post),
                onDownloadGpx:
                    (post.routeAttachment?.points.length ?? 0) >= 2 ||
                        (post.shareGpx && post.rideId != null)
                    ? () => _downloadGpx(post)
                    : null,
              );
            },
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Column(
              children: [
                if (_pageError != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(_pageError!),
                  ),
                if (_loadingMore)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_canLoadMore)
                  OutlinedButton(
                    onPressed: _loadMore,
                    child: Text(
                      _pageError == null
                          ? 'Предыдущие публикации'
                          : 'Повторить загрузку',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _openAuthorProfile(CommunityPost post) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PublicProfileScreen(
          userId: post.authorId,
          preloaded: FriendProfile(
            id: post.authorId,
            username: post.authorName,
            avatarUrl: post.authorAvatarUrl,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(
            Icons.forum,
            size: 56,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            _type == CommunityPostType.all ? 'Лента пуста' : 'Публикаций этого формата пока нет',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            switch (_scope) {
              CommunityFeedScope.everyone =>
                'Поделитесь поездкой или маршрутом с другими райдерами',
              CommunityFeedScope.friends => 'Здесь появятся публикации друзей. Найдите райдеров во вкладке поиска.',
              CommunityFeedScope.mine =>
                'Ваши публикации и прикреплённые поездки появятся здесь',
            },
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          if (_scope == CommunityFeedScope.friends &&
              widget.onFindFriends != null)
            FilledButton.icon(
              onPressed: widget.onFindFriends,
              icon: const Icon(Icons.person_search_outlined),
              label: const Text('Найти людей'),
            )
          else if (_scope != CommunityFeedScope.friends)
            FilledButton.icon(
              onPressed: _moderation.isBanned ? null : _openComposer,
              icon: const Icon(Icons.edit_note),
              label: const Text('Написать публикацию'),
            ),
        ],
      ),
    );
  }
}

/// Диалог публикации: текст, до 4 фото, заезд с опциональным GPX.
class _ComposerDialog extends StatefulWidget {
  const _ComposerDialog({this.route});
  final SavedRoute? route;

  @override
  State<_ComposerDialog> createState() => __ComposerDialogState();
}

class __ComposerDialogState extends State<_ComposerDialog> {
  final TextEditingController _bodyController = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  final CommunityService _communityService = CommunityService();

  bool _isLoadingRides = true;
  bool _publishing = false;
  bool _allowClose = false;
  bool _draftReady = false, _draftPublished = false;
  String? _draftNotice;
  CommunityDraftStore? _draftStore;
  CommunityPostAudience _audience = CommunityPostAudience.everyone;
  bool get _sameOwner =>
      _publicationOwner != null &&
      _publicationOwner == _communityService.userId;
  Future<bool> _saveDraft() async {
    if (!_draftReady || _draftPublished || !_sameOwner) return true;
    try {
      await _draftStore?.write({
        'body': _bodyController.text,
        'photos': List<String>.of(_photoPaths),
        'video': _videoPath,
        'topics': _selectedTopics.toList(),
        'ride_id': _selectedRideId,
        'audience': _audience.name,
      });
      if (mounted && _draftNotice == 'Не удалось сохранить черновик')
        setState(() => _draftNotice = null);
      return true;
    } catch (_) {
      if (mounted)
        setState(() => _draftNotice = 'Не удалось сохранить черновик');
      return false;
    }
  }

  Future<void> _initializeDraft() async {
    await _loadRecentRides();
    if (!mounted || !_sameOwner) return;
    _draftStore = CommunityDraftStore(_publicationOwner!);
    try {
      final draft = await _draftStore!.read();
      if (!mounted || !_sameOwner) return;
      var restore = draft != null;
      if (draft != null && widget.route != null) {
        restore =
            await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Есть незаконченная публикация'),
                content: const Text(
                  'Восстановить черновик или начать новую публикацию выбранного заезда?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Восстановить'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Начать новую'),
                  ),
                ],
              ),
            ) ??
            true;
      }
      if (!mounted || !_sameOwner) return;
      if (restore && draft != null) {
        _bodyController.text = (draft['body'] as String? ?? '').substring(
          0,
          ((draft['body'] as String? ?? '').length).clamp(0, 1000),
        );
        final savedPhotos = (draft['photos'] as List? ?? [])
            .whereType<String>()
            .take(4);
        _photoPaths.clear();
        for (final path in savedPhotos) {
          if (await File(path).exists()) _photoPaths.add(path);
        }
        if (!mounted || !_sameOwner) return;
        final savedVideo = draft['video'] as String?;
        _videoPath = savedVideo != null && await File(savedVideo).exists() ? savedVideo : null;
        _selectedTopics.addAll((draft['topics'] as List? ?? []).whereType<String>());
        final rideId = draft['ride_id'] as String?;
        _selectedRideId = _rideByLocalId.containsKey(rideId) ? rideId : null;
        _audience = draft['audience'] == 'friends'
            ? CommunityPostAudience.friends
            : CommunityPostAudience.everyone;
        _shareGpx = false;
        _rideMediaIds = {};
        _draftNotice = 'Черновик восстановлен. Проверьте вложения и доступ к треку перед публикацией.';
      }
    } catch (_) {
      _draftNotice = 'Не удалось восстановить черновик. Его исходная копия сохранена на устройстве.';
    }
    if (!mounted || !_sameOwner) return;
    setState(() => _draftReady = true);
    await _saveDraft();
  }

  bool get _hasDraft =>
      _bodyController.text.trim().isNotEmpty ||
      _photoPaths.isNotEmpty || _videoPath != null ||
      _selectedRideId != null;
  Future<void> _closeComposer() async {
    if (_publishing) return;
    final saved = await _saveDraft();
    if (!mounted) return;
    if (!saved) {
      final exit = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Черновик не сохранён'),
          content: const Text(
            'Не удалось сохранить изменения на устройстве. Можно остаться в редакторе и повторить сохранение.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Остаться'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Выйти без сохранения'),
            ),
          ],
        ),
      );
      if (exit != true || !mounted) return;
    }
    setState(() => _allowClose = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  String? _ridesError;
  List<({String id, String label})> _recentRides = [];
  String? _selectedRideId;
  final Map<String, SavedRoute> _rideByLocalId = {};
  bool _shareGpx = false;
  int _hideRadius = 200;
  final List<String> _photoPaths = [];
  String? _videoPath;
  final Set<String> _selectedTopics = {};
  final Set<String> _plannedRouteIds = {};
  Set<String> _rideMediaIds = {};
  late final String? _publicationOwner;

  @override
  void initState() {
    super.initState();
    _publicationOwner = _communityService.userId;
    _bodyController.addListener(_contentChanged);
    final route = widget.route;
    if (route != null) {
      _bodyController.text =
          '${route.activityType.label}: ${route.distanceKm.toStringAsFixed(1)} км';
      _selectedRideId = route.localId;
      _rideByLocalId[route.localId] = route;
    }
    unawaited(_initializeDraft());
  }

  @override
  void dispose() {
    unawaited(_saveDraft());
    _bodyController.dispose();
    super.dispose();
  }

  /// Последние заезды для прикрепления (из локальной истории).
  void _contentChanged() {
    if (mounted) {
      setState(() {});
      unawaited(_saveDraft());
    }
  }

  Future<void> _loadRecentRides() async {
    try {
      final choices = await CommunityRouteChoices().loadChoices();
      if (!mounted || !_sameOwner) return;
      setState(() {
        for (final choice in choices) {
          final key = '${choice.kind}:${choice.route.localId}';
          _rideByLocalId[key] = choice.route;
          if (choice.kind == 'route') _plannedRouteIds.add(key);
          if (choice.kind == 'ride') _rideByLocalId[choice.route.localId] = choice.route;
        }
        _recentRides = choices.map((c) => (id: '${c.kind}:${c.route.localId}', label: c.route.title)).toList();
        _isLoadingRides = false;
        _ridesError = null;
      });
    } catch (_) {
      if (!mounted || !_sameOwner) return;
      setState(() { _isLoadingRides = false; _ridesError = 'Не удалось прочитать маршруты и тренировки'; });
    }
  }

  Future<void> _chooseRoute() async {
    await showCommunityRoutePicker(context,
      selected: _rideByLocalId[_selectedRideId],
      source: _selectedRideId == null ? null : _plannedRouteIds.contains(_selectedRideId) ? CommunityRouteSource.saved : CommunityRouteSource.workout,
      onSelectedChoice: (choice) {
        if (!mounted || !_sameOwner) return;
        final key = '${choice.kind}:${choice.route.localId}';
        setState(() {
          _rideByLocalId[key] = choice.route;
          choice.kind == 'route' ? _plannedRouteIds.add(key) : _plannedRouteIds.remove(key);
          _selectedRideId = key;
          _shareGpx = false;
          _rideMediaIds = {};
        });
        unawaited(_saveDraft());
      },
    );
  }

  Future<void> _pickVideo() async {
    try {
      final file = await _picker.pickVideo(source: ImageSource.gallery);
      if (file == null || !mounted || !_sameOwner) return;
      _draftStore ??= CommunityDraftStore(_publicationOwner!);
      final path = await _draftStore!.stageVideo(file.path);
      if (!mounted || !_sameOwner) return;
      setState(() => _videoPath = path);
      await _saveDraft();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error is FormatException ? error.message : 'Не удалось выбрать видео')));
    }
  }

  Future<void> _pickPhotos() async {
    if (_photoPaths.length >= 4) return;
    try {
      final picked = await _picker.pickMultiImage(
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
      if (!mounted || !_sameOwner) return;
      final paths = <String>[];
      _draftStore ??= CommunityDraftStore(_publicationOwner!);
      for (final image in picked.take(4 - _photoPaths.length)) {
        paths.add(await _draftStore!.stagePhoto(image.path));
        if (!mounted || !_sameOwner) return;
      }
      setState(() => _photoPaths.addAll(paths));
      await _saveDraft();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Не удалось выбрать фото')));
    }
  }

  Future<void> _publish() async {
    if (_publishing || _draftPublished || !_sameOwner || !_draftReady) return;
    final body = _bodyController.text.trim();
    if (body.isEmpty && _photoPaths.isEmpty && _videoPath == null && _selectedRideId == null) return;
    setState(() => _publishing = true);
    try {
      final owner = _publicationOwner;
      if (owner == null || owner != _communityService.userId) {
        throw StateError('Аккаунт изменился. Откройте публикацию заново.');
      }
      final selectedRoute = _rideByLocalId[_selectedRideId];
      final SharedRoute? snapshot = selectedRoute == null
          ? null
          : await RideMediaService.prepareShare(
              selectedRoute,
              kind: _plannedRouteIds.contains(_selectedRideId) ? 'route' : 'ride',
              selectedIds: _shareGpx ? _rideMediaIds : {},
              includeTrack: _shareGpx,
              hideRadiusMeters: _hideRadius.toDouble(),
            );
      if (!mounted || owner != _communityService.userId) return;
      await _communityService.createPost(
        body,
        audience: _audience,
        expectedOwner: owner,
        rideId: _plannedRouteIds.contains(_selectedRideId) ? null : _rideByLocalId[_selectedRideId]?.remoteId,
        routeAttachment: snapshot,
        photoPaths: _photoPaths,
        videoPath: _videoPath,
        topics: _selectedTopics.toList(),
        // Snapshot GPX includes only the points visible in the post. Do not
        // grant the legacy RPC access to the original untrimmed ride.
        shareGpx: false,
      );
      _draftPublished = true;
      try {
        await _draftStore?.clear();
      } catch (_) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Публикация отправлена. Не удалось очистить локальный черновик.',
              ),
            ),
          );
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } on CommunityServiceException catch (error) {
      if (!mounted) return;
      setState(() => _publishing = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _publishing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось опубликовать. Проверьте сеть и вложения. Текст остаётся в открытом редакторе.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_publishing && (!_hasDraft || _allowClose),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeComposer();
      },
      child: CommunityComposerFrame(
        busy: _publishing || !_draftReady || !_sameOwner,
        onClose: _publishing ? null : _closeComposer,
        title: const Text('Новая публикация'),
        content: SizedBox(
          width: double.infinity,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    'Расскажите о поездке. Фото и заезд можно добавить по желанию.',
                  ),
                ),
                if (!_draftReady) const LinearProgressIndicator(),
                if (_draftNotice != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_draftNotice!),
                  ),
                DropdownButtonFormField<CommunityPostAudience>(
                  initialValue: _audience,
                  key: ValueKey(_audience),
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Кто увидит публикацию',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: CommunityPostAudience.everyone,
                      child: Text('Все пользователи'),
                    ),
                    DropdownMenuItem(
                      value: CommunityPostAudience.friends,
                      child: Text('Только друзья'),
                    ),
                  ],
                  onChanged: _publishing
                      ? null
                      : (value) {
                          if (value != null) {
                            setState(() => _audience = value);
                            unawaited(_saveDraft());
                          }
                        },
                ),
                const SizedBox(height: 16),
                TextField(
                  enabled: !_publishing,
                  controller: _bodyController,
                  maxLines: 5,
                  maxLength: 1000,
                  autofocus: false,
                  decoration: const InputDecoration(
                    hintText: 'Что нового? Как прошла тренировка?',
                    border: OutlineInputBorder(),
                  ),
                ),
                // Фото: превью или кнопка добавления (до 4).
                if (_photoPaths.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final path in _photoPaths)
                          Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  File(path),
                                  width: 72,
                                  height: 72,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              Positioned(
                                right: 0,
                                top: 0,
                                child: GestureDetector(
                                  onTap: () => setState(() {
                                    _photoPaths.remove(path);
                                    unawaited(_saveDraft());
                                  }),
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.close,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        if (_photoPaths.length < 4)
                          GestureDetector(
                            onTap: _pickPhotos,
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.add_photo_alternate_outlined,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  )
                else
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _publishing ? null : _pickPhotos,
                      icon: const Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 18,
                      ),
                      label: const Text(
                        'Добавить фото (до 4)',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(onPressed: _publishing ? null : _pickVideo,
                    icon: const Icon(Icons.video_library_outlined), label: Text(_videoPath == null ? 'Добавить видео · до 50 МБ' : 'Заменить видео')),
                  if (_videoPath != null) InputChip(label: const Text('Видео прикреплено'), onDeleted: _publishing ? null : () {setState(() => _videoPath = null); unawaited(_saveDraft());}),
                ]),
                const SizedBox(height: 12),
                const Text('Темы публикации · можно выбрать несколько'),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final topic in CommunityPostTopic.values)
                    FilterChip(label: ConstrainedBox(constraints: BoxConstraints(maxWidth: (MediaQuery.sizeOf(context).width - 80).clamp(90, 400).toDouble()), child: Text(topic.label, softWrap: true, maxLines: 4, overflow: TextOverflow.visible)), selected: _selectedTopics.contains(topic.id),
                      onSelected: _publishing ? null : (selected) {setState(() => selected ? _selectedTopics.add(topic.id) : _selectedTopics.remove(topic.id)); unawaited(_saveDraft());}),
                ]),
                if (_ridesError != null)
                  TextButton(
                    onPressed: _loadRecentRides,
                    child: Text('$_ridesError · повторить'),
                  ),
                if (_isLoadingRides)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Маршруты и тренировки · ${_recentRides.length}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  OutlinedButton.icon(
                    onPressed: _publishing ? null : _chooseRoute,
                    icon: const Icon(Icons.route_outlined),
                    label: Text(_selectedRideId == null ? 'Выбрать маршрут или тренировку' : 'Изменить прикреплённый маршрут'),
                  ),
                  if (_selectedRideId != null) ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_rideByLocalId[_selectedRideId]!.title),
                    subtitle: Text(_plannedRouteIds.contains(_selectedRideId) ? 'Сохранённый маршрут' : 'Тренировка'),
                    trailing: IconButton(tooltip: 'Убрать вложение', icon: const Icon(Icons.close), onPressed: _publishing ? null : () {setState(() { _selectedRideId = null; _shareGpx = false; _rideMediaIds = {}; }); unawaited(_saveDraft());}),
                  ),
                  // Приватность трека: GPX уедет в пост только с согласия.
                  if (_selectedRideId != null)
                    TrackPrivacyPicker(
                      key: ValueKey(_selectedRideId),
                      route: _rideByLocalId[_selectedRideId]!,
                      enabled: _shareGpx,
                      radius: _hideRadius,
                      onEnabled: (value) => setState(() => _shareGpx = value),
                      onRadius: (value) => setState(() => _hideRadius = value),
                    ),
                  if (_selectedRideId != null)
                    RideMediaSelection(
                      key: ValueKey('media_$_selectedRideId'),
                      rideId: _rideByLocalId[_selectedRideId]!.localId,
                      enabled: _shareGpx,
                      busy: _publishing,
                      onChanged: (ids) => _rideMediaIds = ids,
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _publishing ? null : _closeComposer,
            child: const Text('Закрыть'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepOrange,
              foregroundColor: Colors.white,
            ),
            onPressed:
                !_draftReady ||
                    !_sameOwner ||
                    _draftPublished ||
                    _publishing ||
                    (_bodyController.text.trim().isEmpty &&
                        _photoPaths.isEmpty &&
                        _videoPath == null &&
                        _selectedRideId == null)
                ? null
                : _publish,
            child: _publishing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Опубликовать'),
          ),
        ],
      ),
    );
  }
}

/// Мост к истории заездов: композеру нужны последние заезды пользователя
/// для прикрепления. Локальные заезды передаются снимком без cloud ID.
class CommunityRidesBridge {
  Future<List<RideSummary>> recentRides({int? limit = 3}) async {
    final repo = WorkoutHistoryRepository();
    await repo.load();
    return repo.workoutHistoryDesc
        .take(limit ?? repo.workoutHistoryDesc.length)
        .map((route) {
          return RideSummary(
            route: route,
            remoteId: route.remoteId,
            distanceKm: route.distanceKm,
            duration: route.duration,
          );
        })
        .toList();
  }
}

class RideSummary {
  final SavedRoute route;
  final String? remoteId;
  final double distanceKm;
  final String duration;

  const RideSummary({
    required this.route,
    this.remoteId,
    required this.distanceKm,
    required this.duration,
  });
}
