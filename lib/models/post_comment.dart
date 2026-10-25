/// Комментарий к посту сообщества (таблица `post_comments`).
///
/// Ветки: [parentCommentId] — id комментария-родителя (null = верхний
/// уровень). Комментарий содержит текст и/или фото.
class PostComment {
  final String id;
  final String postId;
  final String authorId;

  // Из публичной проекции профиля автора.
  final String authorName;
  final String? authorAvatarUrl;

  /// null — это ответ (reply) на [parentCommentId].
  final String? parentCommentId;

  final String body;
  final String? photoUrl;
  final DateTime createdAt;

  const PostComment({
    required this.id,
    required this.postId,
    required this.authorId,
    required this.authorName,
    this.authorAvatarUrl,
    this.parentCommentId,
    required this.body,
    this.photoUrl,
    required this.createdAt,
  });

  bool get isReply => parentCommentId != null;

  factory PostComment.fromRow(
    Map<String, dynamic> row, {
    required Map<String, Map<String, dynamic>> authorById,
  }) {
    final authorId = (row['author_id'] ?? '').toString();
    final author = authorById[authorId] ?? {};
    return PostComment(
      id: (row['id'] ?? '').toString(),
      postId: (row['post_id'] ?? '').toString(),
      authorId: authorId,
      authorName: (author['username'] as String?)?.trim().isNotEmpty == true
          ? (author['username'] as String).trim()
          : 'Райдер',
      authorAvatarUrl: author['avatar_url'] as String?,
      parentCommentId: (row['parent_comment_id'] ?? '').toString().isEmpty
          ? null
          : (row['parent_comment_id'] ?? '').toString(),
      body: row['body'] as String? ?? '',
      photoUrl: row['photo_url'] as String?,
      createdAt:
          DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
