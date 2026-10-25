import 'package:flutter/material.dart';

import '../models/community_post.dart';
import 'shared_route_card.dart';

/// Карточка поста сообщества: автор, текст, плашка заезда, лайк, удаление.
class CommunityPostCard extends StatelessWidget {
  final CommunityPost post;

  /// Действующий пользователь (для показа корзины на своих постах).
  final String? currentUserId;
  final VoidCallback? onLike;
  final VoidCallback onAuthorTap;
  final VoidCallback? onDelete;
  final VoidCallback? onModerate;

  /// Открыть комментарии (экран со списком и вводом).
  final VoidCallback? onOpenComments;

  /// Скачать GPX-трек прикреплённого заезда (если автор разрешил).
  final VoidCallback? onDownloadGpx;

  const CommunityPostCard({
    super.key,
    required this.post,
    required this.currentUserId,
    required this.onLike,
    required this.onAuthorTap,
    this.onDelete,
    this.onModerate,
    this.onOpenComments,
    this.onDownloadGpx,
  });

  String get _timeAgo {
    final diff = DateTime.now().difference(post.createdAt);
    if (diff.inMinutes < 1) return 'только что';
    if (diff.inMinutes < 60) return '${diff.inMinutes} мин назад';
    if (diff.inHours < 24) return '${diff.inHours} ч назад';
    if (diff.inDays < 7) return '${diff.inDays} дн назад';
    final local = post.createdAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year}';
  }

  String get _rideSummary {
    if (post.rideDistanceKm == null) return 'Заезд';
    final km = post.rideDistanceKm!.toStringAsFixed(1);
    if (post.rideDurationSeconds != null && post.rideDurationSeconds! > 0) {
      final minutes = post.rideDurationSeconds! ~/ 60;
      final hours = minutes ~/ 60;
      final mins = minutes % 60;
      final duration = hours > 0 ? '$hours ч $mins мин' : '$mins мин';
      return '🚴 $km км · $duration';
    }
    return '🚴 $km км';
  }

  /// Сетка фотографий: 1 фото — во всю ширину, остальные — 2 колонки.
  Widget _buildPhotoGrid(List<String> urls) {
    if (urls.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          urls.first,
          width: double.infinity,
          height: 180,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            height: 100,
            color: Colors.grey.shade200,
            child: const Icon(Icons.broken_image_outlined, color: Colors.grey),
          ),
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
      itemCount: urls.length.clamp(0, 4),
      itemBuilder: (context, index) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(
            urls[index],
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              color: Colors.grey.shade200,
              child: const Icon(
                Icons.broken_image_outlined,
                color: Colors.grey,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMine = currentUserId != null && currentUserId == post.authorId;
    final hasPhoto =
        post.authorAvatarUrl != null &&
        (post.authorAvatarUrl!.startsWith('http://') ||
            post.authorAvatarUrl!.startsWith('https://'));

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Автор: тап — публичный профиль.
            GestureDetector(
              onTap: onAuthorTap,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: Colors.deepOrange.shade50,
                    backgroundImage: hasPhoto
                        ? NetworkImage(post.authorAvatarUrl!)
                        : null,
                    child: hasPhoto
                        ? null
                        : Text(
                            post.authorName.isEmpty
                                ? 'Р'
                                : post.authorName.characters.first
                                      .toUpperCase(),
                            style: const TextStyle(
                              color: Colors.deepOrange,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          post.authorName,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          _timeAgo,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isMine && onDelete != null)
                    IconButton(
                      tooltip: 'Удалить пост',
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 20,
                        color: Colors.grey,
                      ),
                      onPressed: onDelete,
                    ),
                  if (onModerate != null)
                    IconButton(
                      tooltip: 'Модерация публикации',
                      icon: const Icon(Icons.shield_outlined, size: 20),
                      onPressed: onModerate,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // Текст поста.
            if (post.body.isNotEmpty)
              SelectableText(
                post.body,
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
            // Фотографии поста (до 4, сетка 2 колонки).
            if (post.photoUrls.isNotEmpty) ...[
              const SizedBox(height: 10),
              _buildPhotoGrid(post.photoUrls),
            ],
            // Прикреплённый заезд.
            if (post.rideId != null && post.rideDistanceKm != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.deepOrange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.deepOrange.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _rideSummary,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    // Скачать GPX-трек (если автор разрешил).
                    if (post.shareGpx && onDownloadGpx != null)
                      IconButton(
                        tooltip: 'Скачать GPX-трек',
                        icon: const Icon(
                          Icons.download_outlined,
                          size: 20,
                          color: Colors.deepOrange,
                        ),
                        onPressed: onDownloadGpx,
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (post.routeAttachment != null) ...[
              SharedRouteCard(route: post.routeAttachment!),
              if (onDownloadGpx != null &&
                  post.routeAttachment!.points.length >= 2)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: onDownloadGpx,
                    icon: const Icon(Icons.file_download_outlined),
                    label: const Text('Сохранить GPX'),
                  ),
                ),
              const SizedBox(height: 8),
            ],
            // Лайк и комментарии.
            Row(
              children: [
                InkWell(
                  onTap: onLike,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          post.likedByMe
                              ? Icons.favorite
                              : Icons.favorite_border,
                          size: 20,
                          color: post.likedByMe
                              ? Colors.deepOrange
                              : Colors.grey,
                        ),
                        if (post.likeCount > 0) ...[
                          const SizedBox(width: 5),
                          Text(
                            '${post.likeCount}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: post.likedByMe
                                  ? Colors.deepOrange
                                  : Colors.grey,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (onOpenComments != null)
                  InkWell(
                    onTap: onOpenComments,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.chat_bubble_outline,
                            size: 18,
                            color: Colors.grey,
                          ),
                          if (post.commentsCount > 0) ...[
                            const SizedBox(width: 5),
                            Text(
                              '${post.commentsCount}',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
