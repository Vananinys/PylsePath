import 'package:flutter/material.dart';

import '../models/community_post.dart';
import '../models/friend_profile.dart';
import '../services/community_service.dart';
import '../widgets/community_post_card.dart';
import '../widgets/community_post_share_sheet.dart';
import '../widgets/community_post_edit_sheet.dart';
import '../utils/gpx_share.dart';
import 'post_comments_screen.dart';
import 'public_profile_screen.dart';

class CommunityPostScreen extends StatefulWidget {
  const CommunityPostScreen({super.key, required this.postId});
  final String postId;
  @override
  State<CommunityPostScreen> createState() => _CommunityPostScreenState();
}

class _CommunityPostScreenState extends State<CommunityPostScreen> {
  final _service = CommunityService();
  late Future<CommunityPost?> _post;
  late final String? _owner = _service.userId;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _post = _service.fetchPost(widget.postId);
  }

  void _reload() {
    if (mounted) setState(() => _post = _service.fetchPost(widget.postId));
  }

  Future<void> _like(CommunityPost p) async {
    if (_busy || _owner != _service.userId) return;
    setState(() => _busy = true);
    try {
      await _service.toggleLike(p.id, isLiked: p.likedByMe);
      _reload();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось изменить отметку. Повторите.'),
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _gpx(CommunityPost p) async {
    try {
      if (p.routeAttachment != null && p.routeAttachment!.points.length >= 2) {
        await GpxShare.route(context, p.routeAttachment!.toSavedRoute());
        return;
      }
      final data = p.shareGpx && p.rideId != null
          ? await _service.fetchRideGpx(p.rideId!)
          : null;
      if (!mounted) return;
      if (data == null) throw StateError('Unavailable');
      await GpxShare.text(context, data, 'PulsePath_${p.id}');
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Трек недоступен или доступ к нему изменился.'),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Публикация')),
    body: FutureBuilder<CommunityPost?>(
      future: _post,
      builder: (context, snapshot) {
        if (_owner != _service.userId)
          return const Center(
            child: Text('Аккаунт изменился. Откройте публикацию заново.'),
          );
        if (snapshot.connectionState != ConnectionState.done)
          return const Center(child: CircularProgressIndicator());
        final p = snapshot.data;
        if (p == null)
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    snapshot.hasError
                        ? 'Не удалось загрузить публикацию'
                        : 'Публикация удалена или доступ к ней изменился',
                    textAlign: TextAlign.center,
                  ),
                  TextButton(
                    onPressed: _reload,
                    child: const Text('Повторить'),
                  ),
                ],
              ),
            ),
          );
        return RefreshIndicator(
          onRefresh: () async {
            _reload();
            await _post;
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              CommunityPostCard(
                post: p,
                currentUserId: _owner,
                onShare: () => showCommunityPostShare(context, post: p),
                onRefreshVideoUrl: p.videoPath == null ? null : () async =>
                    (await _service.resolvePostMedia(p, expectedOwner: _owner)).videoUrl,
                onLike: _busy ? null : () => _like(p),
                onEdit: p.authorId != _owner ? null : () async {
                  final changed = await showCommunityPostEditor(context,
                    post: p, currentUserId: () => _service.userId,
                    onSave: (body) => _service.updatePostBody(p.id, body, expectedOwner: _owner),
                  );
                  if (changed) _reload();
                },
                onAuthorTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PublicProfileScreen(
                      userId: p.authorId,
                      preloaded: FriendProfile(
                        id: p.authorId,
                        username: p.authorName,
                        avatarUrl: p.authorAvatarUrl,
                      ),
                    ),
                  ),
                ),
                onOpenComments: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PostCommentsScreen(post: p),
                    ),
                  );
                  _reload();
                },
                onDownloadGpx:
                    (p.routeAttachment?.points.length ?? 0) >= 2 ||
                        (p.shareGpx && p.rideId != null)
                    ? () => _gpx(p)
                    : null,
                onRefreshPhotoUrls: p.privatePhotoPaths.isEmpty
                    ? null
                    : () async => (await _service.resolvePostMedia(
                        p,
                        expectedOwner: _owner,
                      )).photoUrls,
              ),
            ],
          ),
        );
      },
    ),
  );
}
