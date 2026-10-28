import 'package:flutter/material.dart';

import '../models/chat_message.dart';

class ChatReplyPreview extends StatelessWidget {
  const ChatReplyPreview({
    super.key,
    required this.message,
    required this.author,
    this.onCancel,
  });
  final ChatMessage? message;
  final String author;
  final VoidCallback? onCancel;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final target = message;
    final thumbnail = target?.videoPosterUrl ?? target?.photoUrl;
    final text = target == null
        ? 'Исходное сообщение удалено или недоступно'
        : target.routeAttachment != null
        ? '${target.routeAttachment!.label}: ${target.routeAttachment!.title}'
        : target.isVoice
        ? 'Голосовое сообщение · ${target.audioSeconds ?? 0} с'
        : target.isVideo
        ? 'Видео${target.videoMetadata == null ? '' : ' · ${target.videoMetadata!.durationLabel}'}'
        : target.isPhoto
        ? ((target.body ?? '').isEmpty ? 'Фото' : target.body!)
        : (target.body?.trim().isNotEmpty ?? false)
        ? target.body!
        : target.sticker ?? 'Сообщение';
    return Container(
      constraints: const BoxConstraints(minHeight: 54),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: colors.primary, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(9, 6, 7, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (thumbnail != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: SizedBox(
                width: 38,
                height: 38,
                child: thumbnail.startsWith('http')
                    ? Image.network(
                        thumbnail,
                        cacheWidth:
                            (38 * MediaQuery.devicePixelRatioOf(context))
                                .round()
                                .clamp(38, 152),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.photo_outlined),
                      )
                    : const Icon(Icons.photo_outlined),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text.replaceAll('\n', ' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurface.withValues(alpha: .8),
                  ),
                ),
              ],
            ),
          ),
          if (onCancel != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onCancel,
              icon: const Icon(Icons.close, size: 18),
            ),
        ],
      ),
    );
  }
}
