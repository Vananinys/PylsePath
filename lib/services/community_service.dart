import '../utils/ride_id.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'moderation_service.dart';

import '../models/community_post.dart';
import '../models/shared_route.dart';
import '../models/post_comment.dart';
import '../utils/file_reader.dart';

/// Ошибка сообщества с готовым для UI текстом.
class CommunityServiceException implements Exception {
  const CommunityServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum CommunityFeedScope { everyone, friends, mine }

enum CommunityPostType { all, text, photos, rides }

/// Лента сообщества: посты с прикреплёнными заездами и лайками
/// (таблицы `community_posts` / `community_post_likes`).
class CommunityService {
  Future<void> _explainModerationDenial(PostgrestException error) async {
    if (error.code != '42501') return;
    try {
      final status = await ModerationService().status();
      if (status.isBanned)
        throw CommunityServiceException(status.banDescription);
    } on CommunityServiceException {
      rethrow;
    } catch (_) {
      /* Preserve the original operation error when status is offline. */
    }
  }

  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  String? get userId => _client?.auth.currentUser?.id;

  String _requireOwner([String? expectedOwner]) {
    final owner = userId;
    if (owner == null || (expectedOwner != null && expectedOwner != owner)) {
      throw const CommunityServiceException(
        'Аккаунт изменился. Откройте сообщество заново.',
      );
    }
    return owner;
  }

  /// Лента постов (свежие сверху) с авторами, лайками и сводками заездов.
  Future<List<CommunityPost>> fetchFeed({
    int limit = 50,
    bool strict = false,
    CommunityFeedScope scope = CommunityFeedScope.everyone,
    CommunityPostType type = CommunityPostType.all,
    DateTime? before,
    String? beforeId,
  }) async {
    final client = _client;
    if (client == null) {
      if (strict) throw StateError('Нет подключения к сообществу');
      return const [];
    }

    final owner = userId;
    try {
      var query = client.from('community_posts').select();
      if (scope == CommunityFeedScope.mine) {
        if (userId == null) return const [];
        query = query.eq('author_id', userId!);
      } else if (scope == CommunityFeedScope.friends) {
        if (userId == null) return const [];
        final friends = await client
            .from('friends')
            .select('friend_id')
            .eq('user_id', userId!)
            .timeout(const Duration(seconds: 12));
        _requireOwner(owner);
        final ids = friends
            .map((row) => row['friend_id'].toString())
            .toSet()
            .toList();
        if (ids.isEmpty) return const [];
        query = query.inFilter('author_id', ids);
      }
      switch (type) {
        case CommunityPostType.all:
          break;
        case CommunityPostType.text:
          query = query.isFilter('ride_id', null)
              .isFilter('route_attachment', null)
              .or('photo_urls.is.null,photo_urls.eq.{}')
              .or('private_photo_paths.is.null,private_photo_paths.eq.{}');
        case CommunityPostType.photos:
          query = query.or('photo_urls.not.eq.{},private_photo_paths.not.eq.{}');
        case CommunityPostType.rides:
          query = query.or('ride_id.not.is.null,route_attachment.not.is.null');
      }
      if (before != null && beforeId != null) {
        if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(beforeId)) {
          throw const CommunityServiceException(
            'Не удалось продолжить ленту. Обновите её.',
          );
        }
        final date = before.toUtc().toIso8601String();
        query = query.or(
          'created_at.lt.$date,and(created_at.eq.$date,id.lt.$beforeId)',
        );
      }
      final posts = await query
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(limit.clamp(1, 100))
          .timeout(const Duration(seconds: 12));
      if (userId != owner) throw StateError('Account changed');
      if (posts.isEmpty) return const [];
      final hydrated = await _hydrate(posts);
      if (userId != owner) throw StateError('Account changed');
      return hydrated;
    } on PostgrestException catch (error) {
      debugPrint('[Community] feed ${error.code}: ${error.message}');
      if (strict) rethrow;
      return const [];
    } catch (error) {
      debugPrint('[Community] feed failed: $error');
      if (strict) rethrow;
      return const [];
    }
  }

  Future<CommunityPost?> fetchPost(String id, {bool strict = true}) async {
    final owner = _requireOwner();
    try {
      final rows = await _client!.from('community_posts').select()
          .eq('id', id).limit(1).timeout(const Duration(seconds: 12));
      _requireOwner(owner);
      if (rows.isEmpty) return null;
      final posts = await _hydrate(rows);
      _requireOwner(owner);
      return posts.first;
    } catch (_) {
      if (strict) rethrow;
      return null;
    }
  }

  Future<void> updatePostBody(String postId, String body,
      {String? expectedOwner}) async {
    final owner = _requireOwner(expectedOwner);
    final clean = body.trim();
    if (clean.characters.length > 1000) {
      throw const CommunityServiceException('Максимум 1000 символов в посте');
    }
    try {
      final rows = await _client!.from('community_posts').select()
          .eq('id', postId).eq('author_id', owner).limit(1)
          .timeout(const Duration(seconds: 12));
      _requireOwner(owner);
      if (rows.isEmpty) {
        throw const CommunityServiceException('Пост удалён или недоступен');
      }
      final row = rows.first;
      final hasAttachment = row['ride_id'] != null || row['route_attachment'] != null ||
          (row['photo_urls'] as List? ?? []).isNotEmpty ||
          (row['private_photo_paths'] as List? ?? []).isNotEmpty;
      if (clean.isEmpty && !hasAttachment) {
        throw const CommunityServiceException('Добавьте текст публикации');
      }
      final updated = await _client!.from('community_posts')
          .update({'body': clean}).eq('id', postId).eq('author_id', owner)
          .select('id').timeout(const Duration(seconds: 15));
      _requireOwner(owner);
      if (updated.isEmpty) {
        throw const CommunityServiceException('Пост удалён или недоступен');
      }
    } on CommunityServiceException {
      rethrow;
    } on PostgrestException catch (error) {
      await _explainModerationDenial(error);
      throw const CommunityServiceException('Не удалось сохранить изменения. Повторите попытку.');
    } catch (_) {
      throw const CommunityServiceException('Нет связи с сообществом. Повторите попытку.');
    }
  }

  /// Посты конкретного автора (секция «Посты» в публичном профиле).
  Future<List<CommunityPost>> fetchUserPosts(
    String authorId, {
    int limit = 10,
    bool strict = false,
  }) async {
    final client = _client;
    if (client == null) return const [];

    try {
      final posts = await client
          .from('community_posts')
          .select()
          .eq('author_id', authorId)
          .order('created_at', ascending: false)
          .limit(limit)
          .timeout(const Duration(seconds: 12));
      if (posts.isEmpty) return const [];

      return await _hydrate(posts);
    } on PostgrestException catch (error) {
      debugPrint('[Community] userPosts ${error.code}: ${error.message}');
      if (strict) rethrow;
      return const [];
    } catch (error) {
      debugPrint('[Community] userPosts failed: $error');
      if (strict) rethrow;
      return const [];
    }
  }

  /// Догружает к постам авторов, лайки и сводки заездов.
  Future<List<CommunityPost>> _hydrate(List<dynamic> posts) async {
    final client = _client!;
    final me = userId;
    final rows = posts
        .map((raw) => Map<String, dynamic>.from(raw))
        .toList(growable: false);

    final authorIds = rows
        .map((row) => (row['author_id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    final rideIds = rows
        .map((row) => (row['ride_id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    final postIds = rows.map((row) => (row['id'] ?? '').toString()).toList();

    // Авторы (публичная проекция — вес/рост/возраст наружу не идут).
    final authorById = <String, Map<String, dynamic>>{};
    if (authorIds.isNotEmpty) {
      final authors = await client
          .from('public_profiles')
          .select('id, username, avatar_url')
          .inFilter('id', authorIds)
          .timeout(const Duration(seconds: 12));
      for (final raw in authors) {
        final author = Map<String, dynamic>.from(raw);
        authorById[(author['id'] ?? '').toString()] = author;
      }
    }

    // Лайки: сколько и поставил ли я.
    final likeCountByPost = <String, int>{};
    final likedByMePosts = <String>{};
    if (postIds.isNotEmpty) {
      final likes = await client
          .from('community_post_likes')
          .select('post_id, user_id')
          .inFilter('post_id', postIds)
          .timeout(const Duration(seconds: 12));
      for (final raw in likes) {
        final like = Map<String, dynamic>.from(raw);
        final postId = (like['post_id'] ?? '').toString();
        likeCountByPost[postId] = (likeCountByPost[postId] ?? 0) + 1;
        if (me != null && (like['user_id'] ?? '').toString() == me) {
          likedByMePosts.add(postId);
        }
      }
    }

    // Сводки заездов (view без GPS-трека).
    final rideById = <String, Map<String, dynamic>>{};
    if (rideIds.isNotEmpty) {
      final rides = await client
          .from('public_ride_summaries')
          .select('id, user_id, distance_km, duration_seconds, created_at')
          .inFilter('id', rideIds)
          .timeout(const Duration(seconds: 12));
      for (final raw in rides) {
        final ride = Map<String, dynamic>.from(raw);
        rideById[(ride['id'] ?? '').toString()] = ride;
      }
    }

    return Future.wait(
      rows.map(
        (row) => resolvePostMedia(
          CommunityPost.fromRow(
            row,
            authorById: authorById,
            likeCountByPost: likeCountByPost,
            likedByMePosts: likedByMePosts,
            rideById: rideById,
          ),
          expectedOwner: me,
        ),
      ),
    );
  }

  Future<CommunityPost> resolvePostMedia(
    CommunityPost post, {
    String? expectedOwner,
  }) async {
    final owner = _requireOwner(expectedOwner);
    if (post.privatePhotoPaths.isEmpty) return post;
    final urls = <String>[
      ...post.photoUrls.where(
        (u) => !u.contains('/object/sign/community_private/'),
      ),
    ];
    for (final path in post.privatePhotoPaths) {
      _requireOwner(owner);
      urls.add(
        await _client!.storage
            .from('community_private')
            .createSignedUrl(path, 300),
      );
    }
    _requireOwner(owner);
    return post.copyWith(photoUrls: urls);
  }

  Future<PostComment> resolveCommentMedia(
    PostComment comment, {
    String? expectedOwner,
  }) async {
    final owner = _requireOwner(expectedOwner);
    final path = comment.privatePhotoPath;
    if (path == null) return comment;
    final url = await _client!.storage
        .from('community_private')
        .createSignedUrl(path, 300);
    _requireOwner(owner);
    return comment.withResolvedPhoto(url);
  }

  /// Загружает фото поста/комментария в бакет `community` и возвращает
  /// публичный URL. Путь: `community/<uid>/<timestamp>.<ext>` — политики
  /// Storage разрешают запись только в свою папку.
  Future<String> uploadPhoto(
    String localFilePath, {
    String? expectedOwner,
    bool privatePhoto = false,
  }) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) {
      throw const CommunityServiceException('Нет сессии. Войдите в аккаунт.');
    }

    try {
      _requireOwner(expectedOwner ?? id);
      final bytes = await readBytesFromPath(localFilePath);
      _requireOwner(id);
      final extension = _extensionOf(localFilePath);
      final objectPath = '$id/post_${newRideId()}$extension';

      final bucket = privatePhoto
          ? 'community_private'
          : AppConfig.communityBucket;
      await client.storage
          .from(bucket)
          .uploadBinary(
            objectPath,
            bytes,
            fileOptions: FileOptions(
              upsert: false,
              cacheControl: '3600',
              contentType: switch (extension) {
                '.png' => 'image/png',
                '.webp' => 'image/webp',
                '.gif' => 'image/gif',
                '.heic' => 'image/heic',
                '.heif' => 'image/heif',
                _ => 'image/jpeg',
              },
            ),
          )
          .timeout(const Duration(seconds: 30));
      _requireOwner(id);
      if (privatePhoto) return objectPath;
      return client.storage
          .from(AppConfig.communityBucket)
          .getPublicUrl(objectPath);
    } on StorageException catch (error) {
      debugPrint('[Community] photo ${error.statusCode}: ${error.message}');
      throw CommunityServiceException(_humanizeStorageError(error));
    } on FileReadException catch (error) {
      throw CommunityServiceException(error.message);
    } catch (error) {
      debugPrint('[Community] uploadPhoto failed: $error');
      throw const CommunityServiceException(
        'Не удалось загрузить фото. Проверьте интернет.',
      );
    }
  }

  /// Создаёт пост: текст до 1000 символов, до 4 фото, опционально заезд
  /// и разрешение на скачивание его GPX-трека.
  Future<void> createPost(
    String body, {
    String? rideId,
    List<String> photoPaths = const [],
    bool shareGpx = false,
    SharedRoute? routeAttachment,
    String? expectedOwner,
    CommunityPostAudience audience = CommunityPostAudience.everyone,
  }) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) {
      throw const CommunityServiceException('Нет сессии. Войдите в аккаунт.');
    }
    _requireOwner(expectedOwner ?? id);
    final paths = List<String>.of(photoPaths.take(4));
    final clean = body.trim().isEmpty && routeAttachment != null
        ? '${routeAttachment.label}: ${routeAttachment.title}'
        : body.trim();
    if (clean.isEmpty && photoPaths.isEmpty) {
      throw const CommunityServiceException(
        'Пост не может быть пустым: добавьте текст или фото',
      );
    }
    if (clean.characters.length > 1000) {
      throw const CommunityServiceException('Максимум 1000 символов в посте');
    }

    try {
      final photoUrls = <String>[];
      final privatePaths = <String>[];
      for (final path in paths) {
        _requireOwner(id);
        final uploaded = await uploadPhoto(
          path,
          expectedOwner: id,
          privatePhoto: audience == CommunityPostAudience.friends,
        );
        if (audience == CommunityPostAudience.friends) {
          privatePaths.add(uploaded);
        } else {
          photoUrls.add(uploaded);
        }
      }

      _requireOwner(id);
      await client
          .from('community_posts')
          .insert({
            'audience': audience.name,
            if (privatePaths.isNotEmpty) 'private_photo_paths': privatePaths,
            'author_id': id,
            'body': clean,
            if (rideId != null && rideId.isNotEmpty) 'ride_id': rideId,
            if (photoUrls.isNotEmpty) 'photo_urls': photoUrls,
            'share_gpx': shareGpx,
            if (routeAttachment != null)
              'route_attachment': routeAttachment.toJson(),
          })
          .timeout(const Duration(seconds: 20));
    } on PostgrestException catch (error) {
      debugPrint('[Community] create ${error.code}: ${error.message}');
      await _explainModerationDenial(error);
      throw const CommunityServiceException(
        'Не удалось опубликовать пост. Проверьте интернет.',
      );
    } on CommunityServiceException {
      rethrow;
    } catch (error, stack) {
      debugPrint('[Community] create failed: ${error.runtimeType}');
      debugPrintStack(stackTrace: stack);
      throw const CommunityServiceException(
        'Не удалось опубликовать пост. Проверьте интернет и повторите.',
      );
    }
  }

  /// GPX-трек прикреплённого заезда. Вернёт значение только если автор
  /// разрешил скачивание (share_gpx), — RLS не отдаст трек чужого заезда.
  Future<String?> fetchRideGpx(String rideId) async {
    final client = _client;
    if (client == null) return null;
    try {
      final gpx =
          await client
                  .rpc('pulsepath_shared_gpx', params: {'p_ride_id': rideId})
                  .timeout(const Duration(seconds: 15))
              as String?;
      return (gpx == null || gpx.isEmpty) ? null : gpx;
    } on PostgrestException catch (error) {
      debugPrint('[Community] gpx ${error.code}: ${error.message}');
      return null;
    }
  }

  // ── Комментарии ──────────────────────────────────────────────────────

  /// Комментарии поста, старые сверху (верхний уровень + ответы).
  Future<List<PostComment>> fetchComments(
    String postId, {
    bool strict = false,
  }) async {
    final client = _client;
    if (client == null) {
      if (strict)
        throw const CommunityServiceException('Нет подключения к комментариям');
      return const [];
    }

    try {
      final rows = await client
          .from('post_comments')
          .select()
          .eq('post_id', postId)
          .order('created_at', ascending: true)
          .timeout(const Duration(seconds: 12));
      if (rows.isEmpty) return const [];

      final authorIds = rows
          .map(
            (raw) => (Map<String, dynamic>.from(raw))['author_id']?.toString(),
          )
          .whereType<String>()
          .toSet()
          .toList();
      final authorById = <String, Map<String, dynamic>>{};
      if (authorIds.isNotEmpty) {
        final authors = await client
            .from('public_profiles')
            .select('id, username, avatar_url')
            .inFilter('id', authorIds)
            .timeout(const Duration(seconds: 12));
        for (final raw in authors) {
          final author = Map<String, dynamic>.from(raw);
          authorById[(author['id'] ?? '').toString()] = author;
        }
      }

      final owner = _requireOwner();
      return await Future.wait(
        rows.map(
          (raw) => resolveCommentMedia(
            PostComment.fromRow(
              Map<String, dynamic>.from(raw),
              authorById: authorById,
            ),
            expectedOwner: owner,
          ),
        ),
      );
    } on PostgrestException catch (error) {
      debugPrint('[Community] comments ${error.code}: ${error.message}');
      if (strict)
        throw const CommunityServiceException(
          'Не удалось загрузить комментарии. Повторите попытку.',
        );
      return const [];
    } catch (error) {
      debugPrint('[Community] comments failed: $error');
      if (strict)
        throw const CommunityServiceException(
          'Нет связи с сообществом. Повторите попытку.',
        );
      return const [];
    }
  }

  /// Публичные сводки заездов пользователя (из view без GPS-трека).
  Future<List<Map<String, dynamic>>> fetchUserRideSummaries(
    String userId,
  ) async {
    final client = _client;
    if (client == null) return const [];
    try {
      final rows = await client
          .from('public_ride_summaries')
          .select('id, user_id, distance_km, duration_seconds, created_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(20)
          .timeout(const Duration(seconds: 12));
      return rows.map((raw) => Map<String, dynamic>.from(raw)).toList();
    } on PostgrestException catch (error) {
      debugPrint('[Community] userRides ${error.code}: ${error.message}');
      return const [];
    } catch (error) {
      debugPrint('[Community] userRides failed: $error');
      return const [];
    }
  }

  /// Количество комментариев по постам (для ленты).
  Future<Map<String, int>> commentsCount(List<String> postIds) async {
    final client = _client;
    if (client == null || postIds.isEmpty) return {};
    try {
      final rows = await client
          .from('post_comments')
          .select('post_id')
          .inFilter('post_id', postIds)
          .timeout(const Duration(seconds: 12));
      final counts = <String, int>{};
      for (final raw in rows) {
        final postId = (raw)['post_id']?.toString() ?? '';
        counts[postId] = (counts[postId] ?? 0) + 1;
      }
      return counts;
    } catch (error) {
      debugPrint('[Community] commentsCount failed: $error');
      return {};
    }
  }

  /// Добавляет комментарий (верхний уровень или ответ: [parentCommentId]).
  /// Либо текст, либо фото — обязательно что-то одно.
  Future<void> addComment(
    String postId, {
    String? body,
    String? parentCommentId,
    String? photoPath,
    String? expectedOwner,
  }) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) {
      throw const CommunityServiceException('Нет сессии. Войдите в аккаунт.');
    }
    _requireOwner(expectedOwner ?? id);
    final clean = body?.trim() ?? '';
    if (clean.isEmpty && photoPath == null) {
      throw const CommunityServiceException('Пустой комментарий');
    }
    if (clean.length > 500) {
      throw const CommunityServiceException(
        'Максимум 500 символов в комментарии',
      );
    }

    try {
      String? photoUrl;
      String? privatePath;
      if (photoPath != null) {
        final post = await client
            .from('community_posts')
            .select('audience')
            .eq('id', postId)
            .single();
        _requireOwner(id);
        final privatePhoto = post['audience'] == 'friends';
        final uploaded = await uploadPhoto(
          photoPath,
          expectedOwner: id,
          privatePhoto: privatePhoto,
        );
        if (privatePhoto) {
          privatePath = uploaded;
        } else {
          photoUrl = uploaded;
        }
      }
      _requireOwner(id);
      await client
          .from('post_comments')
          .insert({
            'post_id': postId,
            'author_id': id,
            'body': clean,
            if (parentCommentId != null && parentCommentId.isNotEmpty)
              'parent_comment_id': parentCommentId,
            if (photoUrl != null) 'photo_url': photoUrl,
            if (privatePath != null) 'private_photo_path': privatePath,
          })
          .timeout(const Duration(seconds: 15));
    } on PostgrestException catch (error) {
      debugPrint('[Community] addComment ${error.code}: ${error.message}');
      await _explainModerationDenial(error);
      throw const CommunityServiceException('Не удалось отправить комментарий');
    } on CommunityServiceException {
      rethrow;
    } catch (_) {
      throw const CommunityServiceException(
        'Не удалось отправить комментарий. Проверьте интернет.',
      );
    }
  }

  /// Удаляет свой комментарий.
  Future<void> deleteComment(String commentId, {String? expectedOwner}) async {
    _requireOwner(expectedOwner);
    final client = _client;
    final owner = userId;
    if (client == null || owner == null)
      throw const CommunityServiceException('Войдите в аккаунт');
    try {
      final deleted = await client
          .from('post_comments')
          .delete()
          .eq('id', commentId)
          .eq('author_id', owner)
          .select('id')
          .timeout(const Duration(seconds: 15));
      if (deleted.isEmpty)
        throw const CommunityServiceException(
          'Комментарий уже удалён или недоступен',
        );
    } on PostgrestException catch (error) {
      debugPrint('[Community] deleteComment ${error.code}: ${error.message}');
      throw const CommunityServiceException(
        'Не удалось удалить комментарий. Повторите попытку.',
      );
    } on CommunityServiceException {
      rethrow;
    } catch (_) {
      throw const CommunityServiceException(
        'Нет связи с сообществом. Повторите попытку.',
      );
    }
  }

  static String _humanizeStorageError(StorageException error) {
    final message = error.message.toLowerCase();
    if (error.statusCode == '404' || message.contains('bucket not found')) {
      return 'Бакет «community» не найден. Выполните SQL-миграцию — '
          'она создаёт бакет автоматически.';
    }
    if (error.statusCode == '403' || message.contains('policy')) {
      return 'Нет прав на загрузку фото. Проверьте политики бакета.';
    }
    return 'Не удалось загрузить фото: ${error.message}';
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    if (dot <= slash || dot == path.length - 1) return '.jpg';
    final extension = path.substring(dot).toLowerCase();
    return extension.length <= 6 ? extension : '.jpg';
  }

  /// Удаляет свой пост.
  Future<void> deletePost(String postId, {String? expectedOwner}) async {
    _requireOwner(expectedOwner);
    final client = _client;
    final owner = userId;
    if (client == null || owner == null) {
      throw const CommunityServiceException(
        'Войдите в аккаунт, чтобы удалить пост',
      );
    }
    try {
      final deleted = await client
          .from('community_posts')
          .delete()
          .eq('id', postId)
          .eq('author_id', owner)
          .select('id')
          .timeout(const Duration(seconds: 15));
      if (deleted.isEmpty) {
        throw const CommunityServiceException('Пост уже удалён или недоступен');
      }
    } on PostgrestException catch (error) {
      debugPrint('[Community] delete ${error.code}: ${error.message}');
      throw const CommunityServiceException(
        'Не удалось удалить пост. Повторите попытку.',
      );
    } on CommunityServiceException {
      rethrow;
    } catch (_) {
      throw const CommunityServiceException(
        'Нет связи с сообществом. Повторите попытку.',
      );
    }
  }

  /// Лайк/снятие лайка. Возвращает новое состояние «лайкнул ли я».
  Future<bool> toggleLike(
    String postId, {
    required bool isLiked,
    String? expectedOwner,
  }) async {
    _requireOwner(expectedOwner);
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) {
      throw const CommunityServiceException('Нет сессии. Войдите в аккаунт.');
    }

    try {
      if (isLiked) {
        await client
            .from('community_post_likes')
            .delete()
            .eq('post_id', postId)
            .eq('user_id', id)
            .timeout(const Duration(seconds: 15));
        return false;
      } else {
        await client
            .from('community_post_likes')
            .upsert({
              'post_id': postId,
              'user_id': id,
            }, onConflict: 'post_id,user_id')
            .timeout(const Duration(seconds: 15));
        return true;
      }
    } on PostgrestException catch (error) {
      debugPrint('[Community] like ${error.code}: ${error.message}');
      throw const CommunityServiceException('Не удалось поставить лайк');
    } catch (_) {
      throw const CommunityServiceException(
        'Не удалось изменить лайк. Проверьте интернет.',
      );
    }
  }
}
