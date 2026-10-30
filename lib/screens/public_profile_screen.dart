import '../services/profile_presentation_service.dart';
import '../widgets/profile_identity_card.dart';
import '../services/activity_service.dart';
import '../widgets/activity_panel.dart';

import 'package:flutter/material.dart';

import 'dart:async';

import '../data/user_scope.dart';
import '../services/moderation_service.dart';
import '../widgets/moderation_dialogs.dart';

import '../models/community_post.dart';
import '../models/friend_profile.dart';
import '../models/user_profile.dart' show RidingType;
import '../services/chat_service.dart';
import '../services/community_service.dart';
import '../services/friend_service.dart';
import '../widgets/community_post_card.dart';
import '../widgets/garage_profile_gallery.dart';
import 'chat_screen.dart';

/// Публичный профиль райдера (то, что видят другие пользователи): имя,
/// аватар, статус, город, тип катания + кнопка «Добавить в друзья».
///
/// Открывается тапом по человеку в результатах поиска на экране друзей.
class PublicProfileScreen extends StatefulWidget {
  final String userId;

  /// Если профиль уже загружен в поиске — показываем сразу, облако не дёргаем.
  final FriendProfile? preloaded;

  const PublicProfileScreen({super.key, required this.userId, this.preloaded});

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  final FriendService _friendService = FriendService();
  final ChatService _chatService = ChatService();
  final CommunityService _communityService = CommunityService();
  final String? _viewer = UserScope.currentUserId();
  bool _canModerate = false;
  Future<void> _loadModerationRights() async {
    try {
      final status = await ModerationService().status();
      if (mounted && UserScope.currentUserId() == _viewer)
        setState(() => _canModerate = status.isModerator);
    } catch (_) {
      /* Public profile works without moderator privileges. */
    }
  }

  FriendProfile? _profile;
  bool _isLoading = true;
  bool _busy = false;
  String? _titleLabel;
  String? _titleIcon;
  ProfilePresentation _presentation = const ProfilePresentation();
  ActivitySummary? _activity;
  bool _activityFailed = false;

  /// Состояние отношений: друзья / заявка отправлена / можно добавить.
  _Relation _relation = _Relation.none;

  @override
  void initState() {
    super.initState();
    unawaited(_loadModerationRights());
    _load();
  }

  Future<void> _load() async {
    try {
      _activity = await ActivityService().load(widget.userId);
      _activityFailed = false;
    } catch (_) {
      _activityFailed = true;
    }
    FriendProfile? profile = widget.preloaded;
    if (profile == null || profile.id != widget.userId) {
      profile = await _friendService.fetchPublicProfile(widget.userId);
    }
    if (!mounted) return;
    try {
      final title = await _friendService.fetchPublicTitle(widget.userId);
      _titleLabel = title?['label'] as String?;
      _titleIcon = title?['icon'] as String?;
    } catch (_) {
      /* Title is optional public profile information. */
    }

    try {
      _presentation = await ProfilePresentationService().load(widget.userId);
    } catch (_) {
      /* Public profile also works without presentation data. */
    }
    if (!mounted) return;

    // Определяем текущий статус отношений.
    final friends = await _friendService.fetchFriends();
    final isFriend = friends.any((friend) => friend.id == widget.userId);
    var relation = isFriend ? _Relation.friends : _Relation.none;
    if (relation == _Relation.none) {
      final outgoing = await _friendService.fetchOutgoingRequests();
      final requested = outgoing.any(
        (request) => request.toUserId == widget.userId,
      );
      if (requested) relation = _Relation.requested;
    }

    if (!mounted) return;
    setState(() {
      _profile = profile;
      _relation = relation;
      _isLoading = false;
    });
  }

  Future<void> _sendRequest() async {
    setState(() => _busy = true);
    try {
      await _friendService.sendRequest(widget.userId);
      if (!mounted) return;
      setState(() => _relation = _Relation.requested);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Заявка в друзья отправлена')),
      );
    } on FriendServiceException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return Scaffold(
      appBar: AppBar(
        title: Text(profile?.username ?? 'Профиль'),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _load,
            tooltip: 'Обновить профиль',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : profile == null
          ? Center(
              child: Text(
                'Профиль не найден',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                ProfileIdentityCard(
                  name: profile.username,
                  avatar: _buildAvatar(profile),
                  style: _presentation,
                  status: profile.status ?? '',
                  city: profile.city ?? '',
                  sport: _ridingTypeLabel(profile),
                  title:
                      _presentation.selectedRank?.name ??
                      _presentation.title?.label ??
                      _titleLabel,
                  titleIcon:
                      _presentation.selectedRank?.icon ??
                      _presentation.title?.icon ??
                      _titleIcon,
                ),
                ProfileAwardsShowcase(style: _presentation),
                const SizedBox(height: 20),
                if (_activity != null) ActivityPanel(summary: _activity!),
                if (_activityFailed)
                  TextButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Активность не загрузилась. Повторить'),
                  ),
                const SizedBox(height: 20),
                _buildInfoTile(
                  Icons.location_on_outlined,
                  'Город',
                  profile.city,
                ),
                _buildInfoTile(
                  Icons.directions_bike_outlined,
                  'Тип катания',
                  _ridingTypeLabel(profile),
                ),
                // Вес/возраст/пол видны, только если пользователь их
                // не скрыл настройкой приватности (скрытое = null).
                if (profile.weightKg != null)
                  _buildInfoTile(
                    Icons.fitness_center_outlined,
                    'Вес',
                    '${profile.weightKg!.toStringAsFixed(0)} кг',
                  ),
                if (profile.age != null)
                  _buildInfoTile(
                    Icons.cake_outlined,
                    'Возраст',
                    '${profile.age} лет',
                  ),
                if (_genderLabel(profile.gender) != null)
                  _buildInfoTile(
                    Icons.person_outline,
                    'Пол',
                    _genderLabel(profile.gender)!,
                  ),
                const SizedBox(height: 28),
                _buildRelationButton(),
                const SizedBox(height: 28),
                const Text(
                  'Велосипеды и публикации',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                _buildAuthorPosts(),
              ],
            ),
    );
  }

  Widget _buildAuthorPosts() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Гараж', style: Theme.of(context).textTheme.titleLarge),
        GarageProfileGallery(userId: widget.userId),
        const SizedBox(height: 16),
        const Text(
          'Посты автора',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        _buildPostsList(),
      ],
    );
  }

  Widget _buildPostsList() {
    return FutureBuilder<List<CommunityPost>>(
      future: _communityService.fetchUserPosts(widget.userId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final posts = snapshot.data ?? const <CommunityPost>[];
        if (posts.isEmpty) {
          return Text(
            'Постов пока нет',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
        }
        return Column(
          children: posts
              .map(
                (post) => CommunityPostCard(
                  post: post,
                  currentUserId: _communityService.userId,
                  onModerate: _canModerate
                      ? () async {
                          final changed = await showPostModeration(
                            context,
                            contentId: post.id,
                            authorId: post.authorId,
                            authorName: post.authorName,
                          );
                          if (changed && mounted) setState(() {});
                        }
                      : null,
                  onLike: () async {
                    final index = posts.indexOf(post);
                    if (index == -1) return;
                    final updated = post.copyWith(
                      likedByMe: !post.likedByMe,
                      likeCount: post.likeCount + (post.likedByMe ? -1 : 1),
                    );
                    setState(() => posts[index] = updated);
                    try {
                      await _communityService.toggleLike(
                        post.id,
                        isLiked: post.likedByMe,
                      );
                    } on CommunityServiceException {
                      setState(() => posts[index] = post);
                    }
                  },
                  onAuthorTap: () {},
                ),
              )
              .toList(),
        );
      },
    );
  }

  Future<void> _openChat() async {
    final profile = _profile;
    if (profile == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ChatScreen(friend: profile)),
    );
    await _chatService.refreshUnread();
  }

  Widget _buildAvatar(FriendProfile profile) {
    final url = profile.avatarUrl;
    final hasUrl =
        url != null &&
        (url.startsWith('http://') || url.startsWith('https://'));
    return CircleAvatar(
      radius: 48,
      backgroundColor: Colors.deepOrange.shade50,
      backgroundImage: hasUrl ? NetworkImage(url) : null,
      child: hasUrl
          ? null
          : Text(
              profile.username.isEmpty
                  ? 'Р'
                  : profile.username.characters.first.toUpperCase(),
              style: const TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: Colors.deepOrange,
              ),
            ),
    );
  }

  Widget _buildInfoTile(IconData icon, String label, String? value) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Icon(icon, color: Colors.deepOrange),
        title: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          (value == null || value.isEmpty) ? 'Не указано' : value,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildRelationButton() {
    if (_relation == _Relation.friends) {
      return Column(
        children: [
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _openChat,
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Написать'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepOrange,
                foregroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, color: Colors.deepOrange),
                SizedBox(width: 8),
                Text(
                  'Вы уже друзья',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (_relation == _Relation.requested) {
      return Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.hourglass_top,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            SizedBox(width: 8),
            Text(
              'Заявка отправлена — ожидаем подтверждения',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton.icon(
        onPressed: _busy ? null : _sendRequest,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.person_add_alt_1),
        label: const Text('Добавить в друзья'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.deepOrange,
          foregroundColor: Colors.white,
        ),
      ),
    );
  }
}

enum _Relation { none, requested, friends }

String? _genderLabel(String? gender) {
  switch (gender) {
    case 'male':
      return 'Мужской';
    case 'female':
      return 'Женский';
    default:
      return null;
  }
}

String _ridingTypeLabel(FriendProfile profile) {
  // preferred_riding_type хранится именем RidingType — мапим в лейбл.
  final name = profile.preferredRidingType;
  if (name == null || name.isEmpty) return '';
  for (final type in RidingType.values) {
    if (type.name == name) return type.label;
  }
  return '';
}
