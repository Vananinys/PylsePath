import 'community_post_topic.dart';
import 'shared_route.dart';

enum CommunityPostAudience { everyone, friends }

/// Пост сообщества (таблица `community_posts`) с агрегатами ленты.
class CommunityPost {
  final CommunityPostAudience audience;
  final SharedRoute? routeAttachment;
  final String id;
  final String authorId;

  // Из публичной проекции профиля автора.
  final String authorName;
  final String? authorAvatarUrl;

  final String body;
  final String? videoPath;
  final String? videoUrl;
  final List<String> topics;
  bool get hasVideo => videoPath != null && videoPath!.isNotEmpty;

  /// Прикреплённый заезд (id из `rides`), может отсутствовать.
  final String? rideId;

  // Сводка прикреплённого заезда (из view `public_ride_summaries`,
  // без GPS-трека — приватный трек наружу не отдаётся).
  final double? rideDistanceKm;
  final int? rideDurationSeconds;
  final DateTime? rideCreatedAt;

  final int likeCount;
  final bool likedByMe;
  final DateTime createdAt;

  /// Фотографии поста (публичные URL из бакета `community`), до 4.
  final List<String> photoUrls;
  final List<String> privatePhotoPaths;

  /// Разрешено ли скачивать GPX-трек прикреплённого заезда.
  final bool shareGpx;

  /// Количество комментариев (считается пакетно при загрузке ленты).
  final int commentsCount;

  const CommunityPost({
    this.routeAttachment,
    this.audience = CommunityPostAudience.everyone,
    required this.id,
    required this.authorId,
    required this.authorName,
    this.authorAvatarUrl,
    required this.body,
    this.videoPath,
    this.videoUrl,
    this.topics = const [],
    this.rideId,
    this.rideDistanceKm,
    this.rideDurationSeconds,
    this.rideCreatedAt,
    required this.likeCount,
    required this.likedByMe,
    required this.createdAt,
    this.photoUrls = const [],
    this.privatePhotoPaths = const [],
    this.shareGpx = false,
    this.commentsCount = 0,
  });

  Map<String, dynamic> toSnapshot() => {
    'audience': audience.name,
    'routeAttachment': routeAttachment?.toJson(),
    'id': id,
    'authorId': authorId,
    'authorName': authorName,
    'authorAvatarUrl': authorAvatarUrl,
    'body': body,
    'videoPath': videoPath,
    'topics': topics,
    'rideId': rideId,
    'rideDistanceKm': rideDistanceKm,
    'rideDurationSeconds': rideDurationSeconds,
    'rideCreatedAt': rideCreatedAt?.toIso8601String(),
    'likeCount': likeCount,
    'likedByMe': likedByMe,
    'createdAt': createdAt.toIso8601String(),
    'photoUrls': photoUrls
        .where((url) => !url.contains('/object/sign/community_private/'))
        .toList(),
    'privatePhotoPaths': privatePhotoPaths,
    'shareGpx': shareGpx,
    'commentsCount': commentsCount,
  };

  factory CommunityPost.fromSnapshot(Map<String, dynamic> row) => CommunityPost(
    audience: row['audience'] == 'friends'
        ? CommunityPostAudience.friends
        : CommunityPostAudience.everyone,
    routeAttachment: SharedRoute.tryParse(row['routeAttachment']),
    id: row['id'] as String,
    authorId: row['authorId'] as String,
    authorName: row['authorName'] as String,
    authorAvatarUrl: row['authorAvatarUrl'] as String?,
    body: row['body'] as String,
    videoPath: row['videoPath'] as String?,
    topics: CommunityPostTopic.normalize(
      (row['topics'] as List? ?? []).cast<String>(),
    ),
    rideId: row['rideId'] as String?,
    rideDistanceKm: (row['rideDistanceKm'] as num?)?.toDouble(),
    rideDurationSeconds: (row['rideDurationSeconds'] as num?)?.toInt(),
    rideCreatedAt: DateTime.tryParse(row['rideCreatedAt'] as String? ?? ''),
    likeCount: row['likeCount'] as int,
    likedByMe: row['likedByMe'] as bool,
    createdAt: DateTime.parse(row['createdAt'] as String),
    photoUrls: (row['photoUrls'] as List).cast<String>(),
    privatePhotoPaths:
        (row['privatePhotoPaths'] as List?)?.cast<String>() ?? const [],
    shareGpx: row['shareGpx'] as bool,
    commentsCount: row['commentsCount'] as int,
  );

  CommunityPost copyWith({
    List<String>? photoUrls,
    String? videoUrl,
    int? likeCount,
    bool? likedByMe,
    int? commentsCount,
  }) {
    return CommunityPost(
      audience: audience,
      routeAttachment: routeAttachment,
      id: id,
      authorId: authorId,
      authorName: authorName,
      authorAvatarUrl: authorAvatarUrl,
      body: body,
      videoPath: videoPath,
      videoUrl: videoUrl ?? this.videoUrl,
      topics: topics,
      rideId: rideId,
      rideDistanceKm: rideDistanceKm,
      rideDurationSeconds: rideDurationSeconds,
      rideCreatedAt: rideCreatedAt,
      likeCount: likeCount ?? this.likeCount,
      likedByMe: likedByMe ?? this.likedByMe,
      createdAt: createdAt,
      photoUrls: photoUrls ?? this.photoUrls,
      privatePhotoPaths: privatePhotoPaths,
      shareGpx: shareGpx,
      commentsCount: commentsCount ?? this.commentsCount,
    );
  }

  factory CommunityPost.fromRow(
    Map<String, dynamic> row, {
    required Map<String, Map<String, dynamic>> authorById,
    required Map<String, int> likeCountByPost,
    required Set<String> likedByMePosts,
    required Map<String, Map<String, dynamic>> rideById,
  }) {
    final postId = (row['id'] ?? '').toString();
    final authorId = (row['author_id'] ?? '').toString();
    final author = authorById[authorId] ?? {};
    final ride = rideById[(row['ride_id'] ?? '').toString()] ?? {};

    return CommunityPost(
      audience: row['audience'] == 'friends'
          ? CommunityPostAudience.friends
          : CommunityPostAudience.everyone,
      routeAttachment: SharedRoute.tryParse(row['route_attachment']),
      id: postId,
      authorId: authorId,
      authorName: (author['username'] as String?)?.trim().isNotEmpty == true
          ? (author['username'] as String).trim()
          : 'Райдер',
      authorAvatarUrl: author['avatar_url'] as String?,
      body: row['body'] as String? ?? '',
      videoPath: row['video_path'] as String?,
      topics: CommunityPostTopic.normalize(
        (row['topics'] as List? ?? []).cast<String>(),
      ),
      rideId: (row['ride_id'] ?? '').toString().isEmpty
          ? null
          : (row['ride_id'] ?? '').toString(),
      rideDistanceKm: ride['distance_km'] is num
          ? (ride['distance_km'] as num).toDouble()
          : null,
      rideDurationSeconds: ride['duration_seconds'] is num
          ? (ride['duration_seconds'] as num).toInt()
          : null,
      rideCreatedAt: DateTime.tryParse(ride['created_at'] as String? ?? ''),
      likeCount: likeCountByPost[postId] ?? 0,
      likedByMe: likedByMePosts.contains(postId),
      createdAt:
          DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
      photoUrls:
          (row['photo_urls'] as List?)?.map((url) => url.toString()).toList() ??
          const [],
      privatePhotoPaths:
          (row['private_photo_paths'] as List?)?.cast<String>() ?? const [],
      shareGpx: row['share_gpx'] as bool? ?? false,
    );
  }
}
