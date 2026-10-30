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
      builder: (_) => _ComposerDialog(route: route),
    ) ??
    false;

/// Лента сообщества: композер «Что нового?» + карточки постов
/// (лайки, комментарии, фото, GPX прикреплённого заезда).
class CommunityFeed extends StatefulWidget {
  const CommunityFeed({super.key});

  @override
  State<CommunityFeed> createState() => _CommunityFeedState();
}

class _CommunityFeedState extends State<CommunityFeed> {
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
    _moderationDebounce?.cancel();
    final channel = _moderationChannel;
    if (channel != null)
      unawaited(Supabase.instance.client.removeChannel(channel));
    super.dispose();
  }

  bool _isLoading = true;
  bool _refreshing = false;
  String? _cacheNotice;
  int _loadGeneration = 0;
  List<CommunityPost> _posts = [];
  static const _pageSize = 20;
  CommunityFeedScope _scope = CommunityFeedScope.everyone;
  bool _canLoadMore = false, _loadingMore = false;
  String? _pageError;
  final _pendingLikes = <String>{};
  String get _cacheName => _scope == CommunityFeedScope.everyone
      ? 'community_feed'
      : 'community_feed_${_scope.name}';

  @override
  void initState() {
    super.initState();
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
          final posts = rows.map(CommunityPost.fromSnapshot).toList();
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
      );
      if (!current()) return;
      setState(() {
        _posts = posts;
        _isLoading = false;
        _cacheNotice = null;
        _canLoadMore = posts.length == _pageSize;
        _loadingMore = false;
        _pageError = null;
      });
      await cache.write(posts.map((post) => post.toSnapshot()).toList());
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
      await cache.write(_posts.map((post) => post.toSnapshot()).toList());
    } catch (_) {
      if (!current()) return;
      setState(() {
        _isLoading = false;
        _loadingMore = false;
        _canLoadMore = false;
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
    await UiSnapshotCache(
      _cacheName,
      owner,
    ).write(_posts.take(100).map((post) => post.toSnapshot()).toList());
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
      _loadingMore = false;
    });
    _load();
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
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final scope in CommunityFeedScope.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(switch (scope) {
                              CommunityFeedScope.everyone => 'Сообщество',
                              CommunityFeedScope.friends => 'Друзья',
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
                OutlinedButton.icon(
                  onPressed: _moderation.isBanned ? null : _openComposer,
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Поделиться поездкой'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.deepOrange,
                    side: BorderSide(
                      color: Colors.deepOrange.withValues(alpha: .4),
                    ),
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
                onLike: _moderation.isBanned ? null : () => _toggleLike(post),
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
            'Лента пуста',
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
  String? _ridesError;
  List<({String id, String label})> _recentRides = [];
  String? _selectedRideId;
  final Map<String, SavedRoute> _rideByLocalId = {};
  bool _shareGpx = false;
  int _hideRadius = 200;
  final List<String> _photoPaths = [];
  Set<String> _rideMediaIds = {};
  late final String? _publicationOwner;

  @override
  void initState() {
    super.initState();
    _publicationOwner = _communityService.userId;
    final route = widget.route;
    if (route != null) {
      _bodyController.text =
          '${route.activityType.label}: ${route.distanceKm.toStringAsFixed(1)} км';
      _selectedRideId = route.localId;
      _rideByLocalId[route.localId] = route;
    }
    _loadRecentRides();
  }

  @override
  void dispose() {
    _bodyController.dispose();
    super.dispose();
  }

  /// Последние заезды для прикрепления (из локальной истории).
  Future<void> _loadRecentRides() async {
    try {
      final repo = CommunityRidesBridge();
      final rides = await repo.recentRides(limit: 10);
      if (!mounted) return;
      setState(() {
        _recentRides = rides
            .map(
              (ride) => (
                id: ride.route.localId,
                label:
                    '${ride.distanceKm.toStringAsFixed(1)} км · ${ride.duration}',
              ),
            )
            .where((ride) => ride.id.isNotEmpty)
            .toList();
        _isLoadingRides = false;
        _ridesError = null;
        _rideByLocalId.addEntries(
          rides.map((ride) => MapEntry(ride.route.localId, ride.route)),
        );
        final initial = widget.route;
        if (initial != null &&
            !_recentRides.any((r) => r.id == initial.localId)) {
          _recentRides.insert(0, (
            id: initial.localId,
            label:
                '${initial.distanceKm.toStringAsFixed(1)} км · ${initial.duration}',
          ));
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingRides = false;
        _ridesError = 'Не удалось прочитать историю заездов';
        final initial = widget.route;
        if (initial != null)
          _recentRides = [
            (
              id: initial.localId,
              label:
                  '${initial.distanceKm.toStringAsFixed(1)} км · ${initial.duration}',
            ),
          ];
      });
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
      if (!mounted) return;
      setState(() {
        for (final image in picked.take(4 - _photoPaths.length)) {
          _photoPaths.add(image.path);
        }
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Не удалось выбрать фото')));
    }
  }

  Future<void> _publish() async {
    if (_publishing) return;
    final body = _bodyController.text.trim();
    if (body.isEmpty && _photoPaths.isEmpty && _selectedRideId == null) return;
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
              selectedIds: _shareGpx ? _rideMediaIds : {},
              includeTrack: _shareGpx,
              hideRadiusMeters: _hideRadius.toDouble(),
            );
      if (!mounted || owner != _communityService.userId) return;
      await _communityService.createPost(
        body,
        rideId: _rideByLocalId[_selectedRideId]?.remoteId,
        routeAttachment: snapshot,
        photoPaths: _photoPaths,
        // Snapshot GPX includes only the points visible in the post. Do not
        // grant the legacy RPC access to the original untrimmed ride.
        shareGpx: false,
      );
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
            'Не удалось подготовить материалы. Проверьте файлы, сеть и формат видео. Попробуйте MP4 с H.264/AAC.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_publishing,
      child: AlertDialog(
        title: const Text('Новый пост'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _bodyController,
                  maxLines: 5,
                  maxLength: 1000,
                  autofocus: true,
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
                                  onTap: () =>
                                      setState(() => _photoPaths.remove(path)),
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
                      onPressed: _pickPhotos,
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
                else if (_recentRides.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Прикрепить заезд:',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _recentRides.map((ride) {
                      final selected = _selectedRideId == ride.id;
                      return FilterChip(
                        label: Text(ride.label),
                        selected: selected,
                        onSelected: (_) => setState(() {
                          _selectedRideId = selected ? null : ride.id;
                          _rideMediaIds = {};
                        }),
                        selectedColor: Colors.deepOrange.withValues(alpha: 0.2),
                        checkmarkColor: Colors.deepOrange,
                      );
                    }).toList(),
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
                      rideId: _selectedRideId!,
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
            onPressed: _publishing ? null : () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepOrange,
              foregroundColor: Colors.white,
            ),
            onPressed: _publishing ? null : _publish,
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
  Future<List<RideSummary>> recentRides({int limit = 3}) async {
    final repo = WorkoutHistoryRepository();
    await repo.load();
    return repo.workoutHistoryDesc.take(limit).map((route) {
      return RideSummary(
        route: route,
        remoteId: route.remoteId,
        distanceKm: route.distanceKm,
        duration: route.duration,
      );
    }).toList();
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
