import 'package:flutter/material.dart';

import '../models/community_post.dart';
import 'shared_route_card.dart';
import 'community_photo_viewer.dart';

/// Карточка поста сообщества: автор, текст, плашка заезда, лайк, удаление.
class CommunityPostCard extends StatelessWidget {
  final CommunityPost post;

  /// Действующий пользователь (для показа корзины на своих постах).
  final String? currentUserId;
  final VoidCallback? onLike;
  final VoidCallback onAuthorTap;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;
  final VoidCallback? onModerate;

  /// Открыть комментарии (экран со списком и вводом).
  final VoidCallback? onOpenComments;

  /// Скачать GPX-трек прикреплённого заезда (если автор разрешил).
  final VoidCallback? onDownloadGpx;
  final Future<List<String>> Function()? onRefreshPhotoUrls;

  const CommunityPostCard({
    super.key,
    required this.post,
    required this.currentUserId,
    required this.onLike,
    required this.onAuthorTap,
    this.onDelete,
    this.onEdit,
    this.onModerate,
    this.onOpenComments,
    this.onDownloadGpx,
    this.onRefreshPhotoUrls,
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
  Widget _buildPhotoGrid(BuildContext context, List<String> urls) {
    if (urls.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: _photo(
          context,
          urls,
          0,
          Image.network(
            urls.first,
            width: double.infinity,
            height: 180,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              height: 100,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Icon(
                Icons.broken_image_outlined,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
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
          child: _photo(
            context,
            urls,
            index,
            Image.network(
              urls[index],
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.broken_image_outlined,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _photo(
    BuildContext context,
    List<String> urls,
    int index,
    Widget child,
  ) => Semantics(
    button: true,
    label: 'Открыть фото ${index + 1} из ${urls.length}',
    child: InkWell(
      onTap: () => Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => CommunityPhotoViewer(
            urls: urls,
            initialIndex: index,
            onRefreshPhotoUrls: onRefreshPhotoUrls,
          ),
        ),
      ),
      child: child,
    ),
  );

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
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if ((isMine && (onDelete != null || onEdit != null)) ||
                      onModerate != null)
                    PopupMenuButton<String>(
                      tooltip: 'Действия с публикацией',
                      onSelected: (action) {
                        if (action == 'edit' && isMine) onEdit?.call();
                        if (action == 'delete') onDelete?.call();
                        if (action == 'moderate') onModerate?.call();
                      },
                      itemBuilder: (_) => [
                        if (isMine && onEdit != null)
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text('Редактировать текст'),
                          ),
                        if (isMine && onDelete != null)
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Удалить пост'),
                          ),
                        if (onModerate != null)
                          const PopupMenuItem(
                            value: 'moderate',
                            child: Text('Модерация публикации'),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            if (post.audience == CommunityPostAudience.friends)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(Icons.group_outlined, size: 16),
                    SizedBox(width: 6),
                    Flexible(child: Text('Только друзья')),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            // Текст поста.
            if (post.body.isNotEmpty)
              _ExpandablePostText(key: ValueKey(post.id), text: post.body),
            // Фотографии поста (до 4, сетка 2 колонки).
            if (post.photoUrls.isNotEmpty) ...[
              const SizedBox(height: 10),
              _buildPhotoGrid(context, post.photoUrls),
            ],
            // Прикреплённый заезд.
            if (post.routeAttachment == null &&
                post.rideId != null &&
                post.rideDistanceKm != null) ...[
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
                  (post.routeAttachment!.points.length >= 2 ||
                      (post.shareGpx && post.rideId != null)))
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
            // Подписанные действия переносятся на узком экране.
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    foregroundColor: post.likedByMe
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  onPressed: onLike,
                  icon: Icon(
                    post.likedByMe ? Icons.favorite : Icons.favorite_border,
                  ),
                  label: Text(
                    '${post.likedByMe ? 'Нравится' : 'Поддержать'} · ${post.likeCount}',
                  ),
                ),
                if (onOpenComments != null)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: onOpenComments,
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: Text('Комментарии · ${post.commentsCount}'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpandablePostText extends StatefulWidget {
  const _ExpandablePostText({super.key, required this.text});
  final String text;
  @override
  State<_ExpandablePostText> createState() => _ExpandablePostTextState();
}

class _ExpandablePostTextState extends State<_ExpandablePostText> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const style = TextStyle(fontSize: 14, height: 1.4);
      final painter = TextPainter(
        text: TextSpan(
          text: widget.text,
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 5,
      )..layout(maxWidth: constraints.maxWidth);
      final overflows = painter.didExceedMaxLines;
      painter.dispose();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (expanded || !overflows)
            SelectableText(widget.text, style: style)
          else
            Text(
              widget.text,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          if (overflows)
            TextButton(
              onPressed: () => setState(() => expanded = !expanded),
              child: Text(expanded ? 'Свернуть' : 'Читать полностью'),
            ),
        ],
      );
    },
  );
}
