import 'package:flutter/services.dart';

import 'dart:async';

import '../data/recent_stickers.dart';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../models/community_post.dart';
import '../models/friend_profile.dart';
import '../services/chat_service.dart';
import '../services/community_service.dart';
import '../services/friend_service.dart';
import '../services/presence_service.dart';
import '../utils/geo_utils.dart';
import '../screens/chat_screen.dart';
import '../screens/post_comments_screen.dart';
import '../screens/public_profile_screen.dart';

/// Вкладки развёрнутой панели друга.
enum _FriendPanelTab { feed, friends, routes }

/// Панель друга на карте (в стиле 2ГИС):
///  - плавающий ряд стикеров НАД панелью (тап — отправить и «прилетит»
///    на маркер, долгое нажатие — «дождь»);
///  - карточка: аватар, имя, расстояние, кнопки Чат/Показать/Поделиться/«…»;
///  - тянется вверх: вкладки Лента / Друзья / Маршруты.
class FriendMapPanel extends StatefulWidget {
  final FriendProfile friend;
  final String? currentUserId;

  /// Позиция пользователя (для расчёта расстояния до друга).
  final ValueListenable<LatLng> myPosition;

  final VoidCallback onClose;
  final VoidCallback onShowOnMap;
  final VoidCallback onShare;
  final VoidCallback onOpenProfile;
  final VoidCallback onRemoveFriend;

  final void Function(String emoji, Offset origin) onSticker;
  final void Function(String emoji, Offset origin) onStickerRain;

  /// Игровая графика (модуль `stickers`): выключается в Лаконичном/
  /// Спортсмене/Городе пресетах. По умолчанию включена — обратная
  /// совместимость для вызовов без настройки.
  final bool showStickers;

  const FriendMapPanel({
    super.key,
    required this.friend,
    required this.currentUserId,
    required this.myPosition,
    required this.onClose,
    required this.onShowOnMap,
    required this.onShare,
    required this.onOpenProfile,
    required this.onRemoveFriend,
    required this.onSticker,
    required this.onStickerRain,
    this.showStickers = true,
  });

  @override
  State<FriendMapPanel> createState() => _FriendMapPanelState();
}

class _FriendMapPanelState extends State<FriendMapPanel> {
  final _recentStore = RecentStickers();
  List<String> _recent = [];
  int _recentRevision = 0;
  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    final revision = ++_recentRevision;
    final owner = widget.currentUserId;
    final items = await _recentStore.load(owner);
    if (mounted && revision == _recentRevision && owner == widget.currentUserId)
      setState(() => _recent = items);
  }

  @override
  void didUpdateWidget(covariant FriendMapPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUserId != widget.currentUserId) {
      _recent = [];
      _loadRecent();
    }
  }

  void _remember(String sticker) {
    _recentRevision++;
    setState(() => _recent = [sticker, ..._recent.where((s) => s != sticker)]);
    unawaited(
      _recentStore
          .used(sticker, widget.currentUserId)
          .catchError((Object _) {}),
    );
  }

  final ChatService _chatService = ChatService();
  final FriendService _friendService = FriendService();
  final CommunityService _communityService = CommunityService();

  _FriendPanelTab _tab = _FriendPanelTab.feed;

  List<CommunityPost> _authorPosts = [];
  Future<List<CommunityPost>>? _authorPostsFuture;

  static const List<String> _quickStickers = [
    '🚴',
    '🔥',
    '💪',
    '⚡',
    '👍',
    '😂',
    '🏆',
    '❤️',
    '🎉',
    '🤝',
    '💩',
    '🥵',
    '😎',
    '🤩',
    '😭',
    '😱',
    '🥇',
    '💨',
    '🚀',
    '🍕',
    '🍺',
    '😴',
  ];

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.44,
      minChildSize: 0.44,
      maxChildSize: 0.88,
      builder: (context, scrollController) {
        return Column(
          children: [
            // Плавающие стикеры НАД карточкой (как в 2ГИС).
            if (widget.showStickers) ...[
              _buildStickerStrip(),
              const SizedBox(height: 8),
            ],
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 14,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  controller: scrollController,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildHeader(),
                      _buildActionRow(),
                      const Divider(height: 24),
                      _buildTabChips(),
                      const SizedBox(height: 8),
                      _buildTabContent(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ── Стикеры (плавающая полоса, прокручивается вправо) ─────────────────

  Widget _buildStickerStrip() {
    final ordered = RecentStickers.order(_quickStickers, _recent);
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _quickStickers.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final sticker = ordered[index];
          var origin = Offset.zero;
          return GestureDetector(
            onTapDown: (details) => origin = details.globalPosition,
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onSticker(sticker, origin);
              _remember(sticker);
            },
            onLongPressStart: (details) {
              HapticFeedback.mediumImpact();
              widget.onStickerRain(sticker, details.globalPosition);
              _remember(sticker);
            },
            child: Container(
              width: 68,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.14),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Center(
                child: Text(sticker, style: const TextStyle(fontSize: 34)),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Заголовок с расстоянием ───────────────────────────────────────────

  Widget _buildHeader() {
    final friend = widget.friend;
    final hasPhoto =
        friend.avatarUrl != null &&
        (friend.avatarUrl!.startsWith('http://') ||
            friend.avatarUrl!.startsWith('https://'));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: Colors.deepOrange.shade50,
            backgroundImage: hasPhoto ? NetworkImage(friend.avatarUrl!) : null,
            child: hasPhoto
                ? null
                : Text(
                    friend.username.isEmpty
                        ? 'Р'
                        : friend.username.characters.first.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.deepOrange,
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  friend.username,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                ListenableBuilder(
                  listenable: PresenceService.instance,
                  builder: (_, __) => Text(
                    '${PresenceService.instance.statusText(friend.id)} · ${friend.motionText}',
                    style: TextStyle(
                      fontSize: 12,
                      color: PresenceService.instance.isOnline(friend.id)
                          ? Colors.green
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Расстояние до друга (как в 2ГИС).
          ValueListenableBuilder<LatLng>(
            valueListenable: widget.myPosition,
            builder: (context, myPos, _) {
              if (friend.liveLatitude == null || friend.liveLongitude == null) {
                return const SizedBox.shrink();
              }
              final meters = GeoUtils.distanceBetween(
                myPos,
                LatLng(friend.liveLatitude!, friend.liveLongitude!),
              );
              final text = meters >= 1000
                  ? '${(meters / 1000).toStringAsFixed(1)} км'
                  : '${meters.round()} м';
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.deepOrange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  text,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.deepOrange,
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Закрыть',
            icon: const Icon(Icons.close),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  // ── Кнопки действий ───────────────────────────────────────────────────

  Widget _buildActionRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: _actionButton(
              icon: Icons.chat_bubble_outline,
              label: 'Чат',
              onTap: _openChat,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _actionButton(
              icon: Icons.my_location,
              label: 'Показать',
              onTap: widget.onShowOnMap,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _actionButton(
              icon: Icons.share_outlined,
              label: 'Поделиться',
              onTap: widget.onShare,
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'profile',
                child: Row(
                  children: [
                    Icon(Icons.person_outline, size: 18),
                    SizedBox(width: 8),
                    Text('Открыть профиль'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'remove',
                child: Row(
                  children: [
                    Icon(
                      Icons.person_remove_outlined,
                      size: 18,
                      color: Colors.redAccent,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Удалить из друзей',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ],
                ),
              ),
            ],
            onSelected: (value) {
              if (value == 'profile') widget.onOpenProfile();
              if (value == 'remove') widget.onRemoveFriend();
            },
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.more_horiz),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 20,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Вкладки ───────────────────────────────────────────────────────────

  Widget _buildTabChips() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          _tabChip('Лента', _FriendPanelTab.feed),
          const SizedBox(width: 8),
          _tabChip('Друзья', _FriendPanelTab.friends),
          const SizedBox(width: 8),
          _tabChip('Маршруты', _FriendPanelTab.routes),
        ],
      ),
    );
  }

  Widget _tabChip(String label, _FriendPanelTab tab) {
    final selected = _tab == tab;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      selectedColor: Colors.deepOrange.withValues(alpha: 0.2),
      labelStyle: TextStyle(
        color: selected
            ? Colors.deepOrange
            : Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
      ),
      onSelected: (_) => setState(() => _tab = tab),
    );
  }

  Widget _buildTabContent() {
    switch (_tab) {
      case _FriendPanelTab.feed:
        return _buildAuthorPosts();
      case _FriendPanelTab.friends:
        return _buildFriendsOf();
      case _FriendPanelTab.routes:
        return _buildRoutesOf();
    }
  }

  // ── Лента (посты с фотографиями) ──────────────────────────────────────

  Widget _buildAuthorPosts() {
    // Подгружаем посты один раз; лайки и комментарии работают полностью.
    _authorPostsFuture ??= _communityService
        .fetchUserPosts(widget.friend.id)
        .then((posts) {
          if (!mounted) return posts;
          setState(() => _authorPosts = posts);
          return posts;
        });

    if (_authorPostsFuture == null) {
      return _emptyText('Постов пока нет');
    }

    return FutureBuilder<List<CommunityPost>>(
      future: _authorPostsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final posts = _authorPosts;
        if (posts.isEmpty) {
          return _emptyText('Постов пока нет');
        }
        return Column(
          children: posts.map((post) {
            final index = posts.indexOf(post);
            return GestureDetector(
              // Тап по посту — комментарии и лайки (полный функционал).
              onTap: () => _openPost(post, index),
              child: Card(
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (post.body.isNotEmpty)
                        Text(
                          post.body,
                          style: const TextStyle(fontSize: 13, height: 1.3),
                        ),
                      // Фотографии поста.
                      if (post.photoUrls.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _buildPostPhotos(post.photoUrls),
                      ],
                      if (post.rideDistanceKm != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          '🚴 ${post.rideDistanceKm!.toStringAsFixed(1)} км',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.deepOrange,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          GestureDetector(
                            onTap: () => _toggleLike(post, index),
                            child: Icon(
                              Icons.favorite,
                              size: 14,
                              color: post.likedByMe
                                  ? Colors.deepOrange
                                  : Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${post.likeCount}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Icon(
                            Icons.chat_bubble_outline,
                            size: 14,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${post.commentsCount}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  /// Открыть пост: комментарии и лайки в полноценном экране.
  Future<void> _openPost(CommunityPost post, int index) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => PostCommentsScreen(post: post)),
    );
    // Обновляем счётчик комментариев после возврата.
    final counts = await _communityService.commentsCount([post.id]);
    if (!mounted) return;
    setState(() {
      _authorPosts[index] = post.copyWith(commentsCount: counts[post.id] ?? 0);
    });
  }

  Future<void> _toggleLike(CommunityPost post, int index) async {
    final updated = post.copyWith(
      likedByMe: !post.likedByMe,
      likeCount: post.likeCount + (post.likedByMe ? -1 : 1),
    );
    setState(() => _authorPosts[index] = updated);
    try {
      await _communityService.toggleLike(post.id, isLiked: post.likedByMe);
    } on CommunityServiceException {
      if (!mounted) return;
      setState(() => _authorPosts[index] = post);
    }
  }

  /// Мини-сетка фотографий поста (1 фото — широко, остальные — 2 колонки).
  Widget _buildPostPhotos(List<String> urls) {
    if (urls.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          urls.first,
          width: double.infinity,
          height: 140,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: 1.2,
      ),
      itemCount: urls.length > 4 ? 4 : urls.length,
      itemBuilder: (context, index) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(
            urls[index],
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        );
      },
    );
  }

  // ── Друзья пользователя ───────────────────────────────────────────────

  Widget _buildFriendsOf() {
    return FutureBuilder<List<FriendProfile>>(
      future: _friendService.fetchFriendsOf(widget.friend.id),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        // Приватность: пользователь скрыл список друзей.
        if (widget.friend.showFriends == false) {
          return _emptyText('Список друзей скрыт настройками приватности');
        }
        final friends = snapshot.data ?? const <FriendProfile>[];
        if (friends.isEmpty) {
          return _emptyText('Друзей пока нет');
        }
        return Column(
          children: friends
              .map(
                (friend) => ListTile(
                  leading: _smallAvatar(friend.avatarUrl, friend.username),
                  title: Text(
                    friend.username,
                    style: const TextStyle(fontSize: 14),
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => PublicProfileScreen(
                          userId: friend.id,
                          preloaded: friend,
                        ),
                      ),
                    );
                  },
                ),
              )
              .toList(),
        );
      },
    );
  }

  // ── Маршруты пользователя ─────────────────────────────────────────────

  Widget _buildRoutesOf() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _communityService.fetchUserRideSummaries(widget.friend.id),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final rides = snapshot.data ?? const <Map<String, dynamic>>[];
        if (rides.isEmpty) {
          return _emptyText('Заездов пока нет');
        }
        return Column(
          children: rides.map((ride) {
            final km = ((ride['distance_km'] as num?) ?? 0).toDouble();
            final seconds = ((ride['duration_seconds'] as num?) ?? 0).toInt();
            final minutes = seconds ~/ 60;
            final date = DateTime.tryParse(ride['created_at'] as String? ?? '');
            final dateText = date == null
                ? ''
                : '${date.day}.${date.month}.${date.year}';
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: const Icon(
                  Icons.route_outlined,
                  color: Colors.deepOrange,
                ),
                title: Text(
                  '${km.toStringAsFixed(1)} км · $minutes мин',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  dateText,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  // ── Общее ─────────────────────────────────────────────────────────────

  Widget _smallAvatar(String? url, String name) {
    final hasPhoto =
        url != null &&
        (url.startsWith('http://') || url.startsWith('https://'));
    return CircleAvatar(
      radius: 18,
      backgroundColor: Colors.deepOrange.shade50,
      backgroundImage: hasPhoto ? NetworkImage(url) : null,
      child: hasPhoto
          ? null
          : Text(
              name.isEmpty ? 'Р' : name.characters.first.toUpperCase(),
              style: const TextStyle(
                color: Colors.deepOrange,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
    );
  }

  Widget _emptyText(String text) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Future<void> _openChat() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(friend: widget.friend),
      ),
    );
    await _chatService.refreshUnread();
  }
}
