import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/shared_route.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/chat_message.dart';
import '../utils/file_reader.dart';

/// Ошибка чата с готовым для UI текстом.
class ChatServiceException implements Exception {
  const ChatServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Личные сообщения между друзьями (таблица `chat_messages`).
///
/// RLS на стороне БД разрешает писать только друзьям — спам от незнакомцев
/// невозможен даже подделанным запросом. Новые сообщения приходят живьём
/// через Realtime ([subscribe]).
class ChatService {
  ChatService._();
  @visibleForTesting
  ChatService.forTesting();
  static final ChatService _instance = ChatService._();
  factory ChatService() => _instance;
  String? _channelUserId;
  int _unreadRequest = 0;
  final Set<String> _delivered = {};
  void resetSession() {
    _unreadRequest++;
    final channel = _channel;
    _channel = null;
    _channelUserId = null;
    if (channel != null) unawaited(channel.unsubscribe());
    _listeners.clear();
    deletionListeners.clear();
    connected.value = false;
    _delivered.clear();
    openChatFriendId = null;
    unreadTotal.value = 0;
  }

  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  String? get userId => _client?.auth.currentUser?.id;

  RealtimeChannel? _channel;

  /// Набор стикеров по категориям (эмодзи, рисуются крупным кеглем).
  static const Map<String, List<String>> stickerCategories = {
    'Спорт': [
      '🚴',
      '🏃',
      '🚵',
      '🛴',
      '🏆',
      '🥇',
      '🎯',
      '💪',
      '⚡',
      '🔥',
      '💨',
      '📈',
    ],
    'Эмоции': [
      '😀',
      '😂',
      '🤩',
      '😤',
      '😴',
      '😎',
      '🤔',
      '😭',
      '🥳',
      '😱',
      '🙌',
      '👍',
    ],
    'Общение': [
      '🤝',
      '👋',
      '💬',
      '📣',
      '❤️',
      '🎉',
      '🎂',
      '☕',
      '🍺',
      '🍕',
      '📸',
      '🔗',
    ],
    'Погода': ['☀️', '🌧️', '⛈️', '❄️', '🌫️', '🌪️', '🌈', '🌡️'],
    'Природа': ['⛰️', '🌲', '🐾', '🌾', '🌊', '🌸', '🦌', '🦅'],
    'Транспорт': ['🚀', '🔧', '📍', '🛞', '🛠️', '🔋', '🧭', '🗺️'],
  };

  /// Отправляет сообщение и возвращает сохранённый вариант с реальным id
  /// (нужен, чтобы заменить оптимистичную копию в UI — иначе отправитель
  /// видел «двойников»: локальная копия + копия из Realtime).
  Future<ChatMessage?> sendMessage(
    String receiverId, {
    String? text,
    String? sticker,
    String? photoPath,
    String? audioPath,
    int? audioSeconds,
    String? replyToId,
    String? messageId,
    bool retry = false,
    SharedRoute? routeAttachment,
  }) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) {
      throw const ChatServiceException('Нет сессии. Войдите в аккаунт.');
    }

    final cleanText = text?.trim() ?? '';
    if (cleanText.length > 4000) {
      throw const ChatServiceException('Максимум 4000 символов');
    }
    final cleanSticker = sticker?.trim() ?? '';
    if (cleanText.isEmpty &&
        cleanSticker.isEmpty &&
        photoPath == null &&
        audioPath == null &&
        routeAttachment == null) {
      throw const ChatServiceException('Пустое сообщение');
    }

    try {
      if (retry && messageId != null) {
        final existing = await fetchMessage(messageId);
        if (existing != null &&
            existing.senderId == id &&
            existing.receiverId == receiverId) {
          return existing;
        }
      }
      // Вложения (фото/голосовые) складываем в бакет `community`.
      String? photoUrl;
      if (photoPath != null) {
        photoUrl = await _uploadAttachment(
          photoPath,
          'photo',
          messageId: messageId,
        );
      }
      String? audioUrl;
      if (audioPath != null) {
        audioUrl = await _uploadAttachment(
          audioPath,
          'voice',
          messageId: messageId,
        );
      }

      final inserted = await client
          .from('chat_messages')
          .insert({
            if (messageId != null) 'id': messageId,
            'sender_id': id,
            'receiver_id': receiverId,
            'body': cleanText.isEmpty ? routeAttachment?.label : cleanText,
            'sticker': cleanSticker.isEmpty ? null : cleanSticker,
            if (replyToId != null && replyToId.isNotEmpty)
              'reply_to_id': replyToId,
            if (photoUrl != null) 'photo_url': photoUrl,
            if (audioUrl != null) 'audio_url': audioUrl,
            if (audioSeconds != null) 'audio_seconds': audioSeconds,
            if (routeAttachment != null)
              'route_attachment': routeAttachment.toJson(),
          })
          .select()
          .single()
          .timeout(const Duration(seconds: 25));
      return await _messageFromRow(Map<String, dynamic>.from(inserted));
    } on PostgrestException catch (error) {
      if (error.code == '23505' && messageId != null) {
        final existing = await fetchMessage(messageId);
        if (existing != null &&
            existing.senderId == id &&
            existing.receiverId == receiverId) {
          return existing;
        }
      }
      debugPrint('[ChatService] send ${error.code}: ${error.message}');
      throw const ChatServiceException(
        'Не удалось отправить сообщение. Проверьте интернет.',
      );
    } on FileReadException catch (error) {
      debugPrint('[ChatService] attachment read: $error');
      throw const ChatServiceException('Не удалось прочитать файл вложения.');
    } on StorageException catch (error) {
      debugPrint('[ChatService] attachment upload: ${error.message}');
      throw const ChatServiceException(
        'Не удалось загрузить вложение. Проверьте интернет.',
      );
    } catch (error) {
      // Timeout и прочие сетевые сбои не должны показывать пользователю
      // сырой текст исключения.
      debugPrint('[ChatService] send failed: $error');
      throw const ChatServiceException(
        'Не удалось отправить сообщение. Проверьте интернет.',
      );
    }
  }

  final List<void Function(ChatMessage message)> _listeners = [];
  final Set<void Function(String)> deletionListeners = {};
  final ValueNotifier<bool> connected = ValueNotifier(false);

  /// Общий счётчик непрочитанных сообщений (для бейджа в дровере).
  static final ValueNotifier<int> unreadTotal = ValueNotifier<int>(0);

  /// id друга, чат с которым сейчас открыт на экране. Используется, чтобы
  /// не показывать баннер «новое сообщение», пока пользователь читает
  /// именно этот диалог (сообщение там и так видно живьём).
  static String? openChatFriendId;

  /// Набор эмодзи-стикеров (без ассетов: рисуются крупным кеглем).
  static const List<String> stickers = [
    '🚴',
    '🏃',
    '⛰️',
    '🔥',
    '💪',
    '🏆',
    '⚡',
    '🎉',
    '👍',
    '😂',
    '🤝',
    '🥇',
    '💨',
    '🚀',
    '😤',
    '😴',
    '🤩',
    '🙌',
    '🐾',
    '🌧️',
    '☀️',
    '🔧',
    '📍',
    '🍺',
  ];

  /// Переписка с другом (оба направления), старые снизу.
  Future<List<ChatMessage>> fetchConversation(
    String friendId, {
    int limit = 60,
    ChatMessage? before,
    String? search,
    bool strict = false,
  }) async {
    final client = _client;
    final id = userId;
    if (client == null || id == null) {
      if (strict) {
        throw const ChatServiceException(
          'Войдите в аккаунт, чтобы загрузить сообщения',
        );
      }
      return const [];
    }
    try {
      Future<List<Map<String, dynamic>>> direction(
        String sender,
        String receiver,
      ) async {
        var query = client
            .from('chat_messages')
            .select()
            .eq('sender_id', sender)
            .eq('receiver_id', receiver);
        if (before != null) {
          final date = before.createdAt.toUtc().toIso8601String();
          query = query.or(
            'created_at.lt.$date,and(created_at.eq.$date,id.lt.${before.id})',
          );
        }
        if (search != null && search.trim().isNotEmpty) {
          final escaped = search
              .trim()
              .replaceAll(r'\', r'\\')
              .replaceAll('%', r'\%')
              .replaceAll('_', r'\_');
          query = query.ilike('body', '%$escaped%');
        }
        final rows = await query
            .order('created_at', ascending: false)
            .order('id', ascending: false)
            .limit(limit)
            .timeout(const Duration(seconds: 15));
        return rows.map((row) => Map<String, dynamic>.from(row)).toList();
      }

      final pages = await Future.wait([
        direction(id, friendId),
        direction(friendId, id),
      ]);
      final rows = [...pages[0], ...pages[1]]
        ..sort((a, b) {
          final date = (b['created_at'] as String).compareTo(
            a['created_at'] as String,
          );
          return date == 0
              ? (b['id'] as String).compareTo(a['id'] as String)
              : date;
        });
      final messages = await _messagesFromRows(
        rows.take(limit).map((row) => Map<String, dynamic>.from(row)).toList(),
      );
      if (userId != id) return const [];
      return messages.reversed.toList();
    } catch (error) {
      debugPrint('[ChatService] conversation: $error');
      if (strict) {
        throw const ChatServiceException(
          'Не удалось загрузить сообщения. Проверьте соединение.',
        );
      }
      return const [];
    }
  }

  Future<ChatMessage?> fetchMessage(String messageId) async {
    final client = _client;
    if (client == null) return null;
    final row = await client
        .from('chat_messages')
        .select()
        .eq('id', messageId)
        .maybeSingle()
        .timeout(const Duration(seconds: 15));
    return row == null ? null : _messageFromRow(Map<String, dynamic>.from(row));
  }

  Future<ChatMessage?> refreshAttachment(ChatMessage message) async {
    if (message.delivery != MessageDelivery.sent) return message;
    return fetchMessage(message.id);
  }

  Future<({bool byMe, bool byThem})> blockState(String friendId) async {
    final client = _client;
    final id = userId;
    if (client == null || id == null) return (byMe: false, byThem: false);
    final rows = await client
        .from('chat_blocks')
        .select('blocker_id, blocked_id')
        .or(
          'and(blocker_id.eq.$id,blocked_id.eq.$friendId),and(blocker_id.eq.$friendId,blocked_id.eq.$id)',
        )
        .timeout(const Duration(seconds: 12));
    return (
      byMe: rows.any((row) => row['blocker_id'] == id),
      byThem: rows.any((row) => row['blocker_id'] == friendId),
    );
  }

  Future<void> setBlocked(String friendId, bool blocked) async {
    final client = _client;
    final id = userId;
    if (client == null || id == null) {
      throw const ChatServiceException('Войдите в аккаунт');
    }
    try {
      if (blocked) {
        await client
            .from('chat_blocks')
            .upsert(
              {'blocker_id': id, 'blocked_id': friendId},
              onConflict: 'blocker_id,blocked_id',
              ignoreDuplicates: true,
            )
            .timeout(const Duration(seconds: 15));
      } else {
        await client
            .from('chat_blocks')
            .delete()
            .eq('blocker_id', id)
            .eq('blocked_id', friendId)
            .timeout(const Duration(seconds: 15));
      }
    } catch (_) {
      throw const ChatServiceException('Не удалось изменить блокировку');
    }
  }

  Future<ChatMessage> editMessage(String messageId, String body) async {
    final id = userId;
    final clean = body.trim();
    if (_client == null || id == null || clean.isEmpty || clean.length > 4000) {
      throw const ChatServiceException('Введите текст до 4000 символов');
    }
    try {
      final row = await _client!
          .from('chat_messages')
          .update({'body': clean})
          .eq('id', messageId)
          .eq('sender_id', id)
          .select()
          .single()
          .timeout(const Duration(seconds: 15));
      return await _messageFromRow(Map<String, dynamic>.from(row));
    } catch (_) {
      throw const ChatServiceException('Не удалось изменить сообщение');
    }
  }

  /// Loads quoted messages outside the current page, using the caller's RLS.
  Future<Map<String, ChatMessage>> fetchReplyTargets(
    Iterable<ChatMessage> messages,
  ) async {
    final ids = messages.map((m) => m.replyToId).whereType<String>().toSet();
    ids.removeAll(messages.map((m) => m.id));
    if (ids.isEmpty || _client == null) return {};
    try {
      final rows = await _client!
          .from('chat_messages')
          .select()
          .inFilter('id', ids.toList())
          .timeout(const Duration(seconds: 15));
      final resolved = await _messagesFromRows(
        rows.map((row) => Map<String, dynamic>.from(row)).toList(),
      );
      return {for (final message in resolved) message.id: message};
    } catch (error) {
      debugPrint('[ChatService] reply targets failed: $error');
      return {};
    }
  }

  /// A preview acknowledges only its own message, never later arrivals.
  Future<bool> markMessageRead(ChatMessage message) async {
    final client = _client;
    final owner = client?.auth.currentUser?.id;
    if (client == null || owner == null || message.receiverId != owner) {
      return false;
    }
    try {
      await client
          .from('chat_messages')
          .update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', message.id)
          .eq('sender_id', message.senderId)
          .eq('receiver_id', owner)
          .filter('read_at', 'is', null)
          .timeout(const Duration(seconds: 12));
      return client.auth.currentUser?.id == owner;
    } catch (error) {
      debugPrint('[ChatService] preview read failed: $error');
      return false;
    }
  }

  /// Отмечает сообщения друга прочитанными (при открытом чате).
  Future<bool> markRead(String friendId) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return false;
    try {
      await client
          .from('chat_messages')
          .update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('sender_id', friendId)
          .eq('receiver_id', id)
          .filter('read_at', 'is', null)
          .timeout(const Duration(seconds: 15));
      return true;
    } catch (error) {
      debugPrint('[ChatService] markRead failed: $error');
      return false;
    }
  }

  /// Удаляет своё сообщение. Возвращает false, если сообщение не ваше
  /// (RLS разрешает удаление только автору) или сети нет.
  Future<bool> deleteMessage(String messageId) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return false;
    try {
      final rows = await client
          .from('chat_messages')
          .delete()
          .eq('id', messageId)
          .eq('sender_id', id)
          .select('id')
          .timeout(const Duration(seconds: 15));
      return rows.isNotEmpty;
    } catch (error) {
      debugPrint('[ChatService] delete failed: $error');
      return false;
    }
  }

  /// Обновляет общий счётчик непрочитанных ([unreadTotal]).
  Future<void> refreshUnread() async {
    final request = ++_unreadRequest;
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) {
      unreadTotal.value = 0;
      return;
    }
    try {
      final response = await client
          .from('chat_messages')
          .select('id')
          .eq('receiver_id', id)
          .filter('read_at', 'is', null)
          .count(CountOption.exact)
          .timeout(const Duration(seconds: 12));
      if (request == _unreadRequest && userId == id) {
        unreadTotal.value = response.count;
      }
    } catch (error) {
      debugPrint('[ChatService] refreshUnread failed: $error');
    }
  }

  /// Непрочитанные по каждому отправителю (для списка диалогов и друзей).
  Future<Map<String, int>> unreadByFriend({bool strict = false}) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return {};

    try {
      final counts = <String, int>{};
      for (var offset = 0; ; offset += 1000) {
        final rows = await client
            .from('chat_messages')
            .select('sender_id')
            .eq('receiver_id', id)
            .filter('read_at', 'is', null)
            .order('id')
            .range(offset, offset + 999)
            .timeout(const Duration(seconds: 15));
        if (userId != id) return {};
        for (final raw in rows) {
          final sender = raw['sender_id']?.toString() ?? '';
          if (sender.isNotEmpty) counts[sender] = (counts[sender] ?? 0) + 1;
        }
        if (rows.length < 1000) break;
      }
      return counts;
    } catch (error) {
      debugPrint('[ChatService] unreadByFriend failed: $error');
      if (strict) rethrow;
      return {};
    }
  }

  /// Последние сообщения с участием меня (для списка диалогов).
  Future<List<ChatMessage>> fetchRecent({
    int limit = 300,
    bool strict = false,
  }) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return const [];

    try {
      final rows = await client
          .from('chat_messages')
          .select()
          .or('sender_id.eq.$id,receiver_id.eq.$id')
          .order('created_at', ascending: false)
          .limit(limit)
          .timeout(const Duration(seconds: 15));
      return await _messagesFromRows(
        rows.map((raw) => Map<String, dynamic>.from(raw)).toList(),
      );
    } on PostgrestException catch (error) {
      debugPrint('[ChatService] recent ${error.code}: ${error.message}');
      if (strict) rethrow;
      return const [];
    } catch (error) {
      debugPrint('[ChatService] recent failed: $error');
      if (strict) rethrow;
      return const [];
    }
  }

  /// Последнее сообщение конкретного диалога для превью списка чатов.
  Future<ChatMessage?> fetchLatestWith(
    String friendId, {
    bool strict = false,
  }) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) {
      if (strict) throw StateError('Нет подключения к аккаунту');
      return null;
    }
    try {
      final rows = await client
          .from('chat_messages')
          .select()
          .or(
            'and(sender_id.eq.$id,receiver_id.eq.$friendId),'
            'and(sender_id.eq.$friendId,receiver_id.eq.$id)',
          )
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(1)
          .timeout(const Duration(seconds: 12));
      if (rows.isEmpty) return null;
      return await _messageFromRow(Map<String, dynamic>.from(rows.first));
    } on PostgrestException catch (error) {
      debugPrint('[ChatService] latest ${error.code}: ${error.message}');
      if (strict) rethrow;
      return null;
    } catch (error) {
      debugPrint('[ChatService] latest failed: $error');
      if (strict) rethrow;
      return null;
    }
  }

  /// Загружает вложение чата (фото/голосовое) в приватный бакет.
  Future<String> _uploadAttachment(
    String localFilePath,
    String prefix, {
    String? messageId,
  }) async {
    final client = _client!;
    final id = client.auth.currentUser!.id;
    final bytes = await readBytesFromPath(localFilePath);
    if (bytes.length > 20 * 1024 * 1024) {
      throw const ChatServiceException('Вложение должно быть меньше 20 МБ');
    }
    final dot = localFilePath.lastIndexOf('.');
    final rawExtension = dot >= 0
        ? localFilePath.substring(dot).toLowerCase()
        : '';
    final extension = prefix == 'voice'
        ? '.m4a'
        : ['.jpg', '.jpeg', '.png', '.webp'].contains(rawExtension)
        ? rawExtension
        : '.jpg';
    final objectPath =
        '$id/chat_${prefix}_${messageId ?? DateTime.now().microsecondsSinceEpoch}$extension';
    final mime = prefix == 'voice'
        ? 'audio/mp4'
        : extension == '.png'
        ? 'image/png'
        : extension == '.webp'
        ? 'image/webp'
        : 'image/jpeg';
    try {
      await client.storage
          .from('chat_media')
          .uploadBinary(
            objectPath,
            bytes,
            fileOptions: FileOptions(
              upsert: false,
              cacheControl: '3600',
              contentType: mime,
            ),
          )
          .timeout(const Duration(seconds: 30));
    } on StorageException catch (error) {
      // A retry reuses the same object rather than uploading orphaned copies.
      if (error.statusCode != '409') rethrow;
    }
    return 'chat:$objectPath';
  }

  Future<ChatMessage> _messageFromRow(Map<String, dynamic> row) async {
    final resolved = Map<String, dynamic>.from(row);
    resolved['photo_reference'] = row['photo_url'];
    resolved['audio_reference'] = row['audio_url'];
    for (final field in ['photo_url', 'audio_url']) {
      final reference = row[field] as String?;
      if (reference != null && reference.startsWith('chat:')) {
        resolved[field] =
            await _signedUrlOrNull(reference.substring(5)) ?? reference;
      }
    }
    return ChatMessage.fromRow(resolved);
  }

  /// Подписанный URL одного вложения; `null` — сервис недоступен (в поле
  /// останется исходная `chat:`-ссылка, UI сможет повторить при перезагрузке).
  Future<String?> _signedUrlOrNull(String path) async {
    try {
      return await _client!.storage
          .from('chat_media')
          .createSignedUrl(path, 3600)
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      // Keep type information; the UI may retry by reopening/refetching the chat.
      return null;
    }
  }

  /// Пакетное разрешение `chat:`-вложений: один запрос подписей на страницу
  /// сообщений вместо отдельного запроса на каждое фото/голосовое.
  Future<List<ChatMessage>> _messagesFromRows(
    List<Map<String, dynamic>> rows,
  ) async {
    final client = _client;
    final paths = <String>{};
    for (final row in rows) {
      for (final field in ['photo_url', 'audio_url']) {
        final reference = row[field] as String?;
        if (reference != null && reference.startsWith('chat:')) {
          paths.add(reference.substring(5));
        }
      }
    }
    final signed = <String, String>{};
    if (client != null && paths.isNotEmpty) {
      final chunks = <List<String>>[];
      for (var start = 0; start < paths.length; start += 50) {
        chunks.add(paths.skip(start).take(50).toList());
      }
      await Future.wait(
        chunks.map((chunk) async {
          try {
            final results = await client.storage
                .from('chat_media')
                .createSignedUrlsResult(chunk, 3600)
                .timeout(const Duration(seconds: 15));
            for (final result in results) {
              final url = result is SignedUrlSuccess
                  ? result.signedUrl
                  : null;
              if (url != null && result.path.isNotEmpty) {
                signed[result.path] = url;
              }
            }
          } catch (error) {
            debugPrint('[ChatService] batch signed urls failed: $error');
          }
        }),
      );
    }
    Future<ChatMessage> convert(Map<String, dynamic> row) async {
      final resolved = Map<String, dynamic>.from(row);
      resolved['photo_reference'] = row['photo_url'];
      resolved['audio_reference'] = row['audio_url'];
      for (final field in ['photo_url', 'audio_url']) {
        final reference = row[field] as String?;
        if (reference != null && reference.startsWith('chat:')) {
          resolved[field] =
              signed[reference.substring(5)] ??
              await _signedUrlOrNull(reference.substring(5)) ??
              reference;
        }
      }
      return ChatMessage.fromRow(resolved);
    }

    return await Future.wait(rows.map(convert));
  }

  /// Подписка на все новые сообщения (один общий Realtime-канал).
  /// [listener] вызывается для каждого сообщения; фильтрация по собеседнику
  /// на стороне подписчика.
  Future<void> subscribe(void Function(ChatMessage message) listener) async {
    final client = _client;
    if (client == null) return;

    final id = userId;
    if (id == null) return;
    if (_channelUserId != null && _channelUserId != id) resetSession();
    if (!_listeners.contains(listener)) _listeners.add(listener);
    if (_channel != null) return;
    _channelUserId = id;
    void deliver(dynamic payload) {
      unawaited(
        () async {
          if (userId != id) return;
          final raw = Map<String, dynamic>.from(payload.newRecord as Map);
          final message = await _messageFromRow(raw);
          if (userId != id ||
              (message.senderId != id && message.receiverId != id)) {
            return;
          }
          if (!_delivered.add(message.id)) return;
          if (_delivered.length > 2000) {
            _delivered.remove(_delivered.first);
          }
          for (final callback in List.of(_listeners)) {
            callback(message);
          }
        }().catchError((Object error) {
          debugPrint('[Chat] realtime decode failed: $error');
        }),
      );
    }

    void deliverUpdate(dynamic payload) {
      unawaited(
        () async {
          if (userId != id) return;
          final raw = Map<String, dynamic>.from(payload.newRecord as Map);
          final message = await _messageFromRow(raw);
          if (userId != id ||
              (message.senderId != id && message.receiverId != id)) {
            return;
          }
          for (final callback in List.of(_listeners)) {
            callback(message);
          }
        }().catchError((Object error) {
          debugPrint('[Chat] realtime update decode failed: $error');
        }),
      );
    }

    try {
      _channel = client
          .channel('chat_messages_$id')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'chat_messages',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'receiver_id',
              value: id,
            ),
            callback: deliver,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'chat_messages',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'sender_id',
              value: id,
            ),
            callback: deliver,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'chat_messages',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'receiver_id',
              value: id,
            ),
            callback: deliverUpdate,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'chat_messages',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'sender_id',
              value: id,
            ),
            callback: deliverUpdate,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.delete,
            schema: 'public',
            table: 'chat_messages',
            callback: (payload) {
              if (userId != id) return;
              final deletedId = payload.oldRecord['id']?.toString();
              if (deletedId != null) {
                for (final listener in List.of(deletionListeners)) {
                  listener(deletedId);
                }
              }
            },
          )
          .subscribe((status, error) {
            if (userId == id) {
              connected.value = status == RealtimeSubscribeStatus.subscribed;
            }
          });
    } catch (error) {
      connected.value = false;
      _channel = null;
      debugPrint('[ChatService] subscribe failed: $error');
    }
  }

  /// Добавляет или удаляет реакцию у сообщения.
  Future<bool> toggleReaction(
    String messageId,
    String reactionEmoji,
    bool add,
  ) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null || messageId.startsWith('local_')) {
      return false;
    }

    try {
      final updated = await client
          .rpc(
            'pulsepath_toggle_chat_reaction',
            params: {
              'p_message_id': messageId,
              'p_emoji': reactionEmoji,
              'p_add': add,
            },
          )
          .timeout(const Duration(seconds: 15));
      final row = updated is List ? updated.single : updated;
      final message = await _messageFromRow(Map<String, dynamic>.from(row));
      for (final callback in List.of(_listeners)) {
        callback(message);
      }
      return true;
    } catch (error) {
      debugPrint('[ChatService] toggleReaction failed: $error');
      return false;
    }
  }

  /// Получает текущие реакции для сообщения.
  Future<Map<String, List<String>>?> getReactions(String messageId) async {
    final client = _client;
    if (client == null) return null;

    try {
      final row = await client
          .from('chat_messages')
          .select('reactions')
          .eq('id', messageId)
          .single()
          .timeout(const Duration(seconds: 12));

      return _parseReactionsJson(row['reactions']);
    } catch (error) {
      debugPrint('[ChatService] getReactions failed: $error');
      return null;
    }
  }

  /// Парсит reactions из JSON.
  static Map<String, List<String>> _parseReactionsJson(dynamic raw) {
    if (raw is! Map) return const {};
    final result = <String, List<String>>{};
    for (final entry in raw.entries) {
      final emoji = entry.key.toString();
      final users = (entry.value as List? ?? const [])
          .map((id) => id.toString())
          .toList();
      if (users.isNotEmpty) result[emoji] = users;
    }
    return result;
  }

  /// Снимает конкретного слушателя (например, при закрытии чата).
  void unsubscribe(void Function(ChatMessage message) listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty) {
      final channel = _channel;
      _channel = null;
      _channelUserId = null;
      if (channel != null) unawaited(channel.unsubscribe());
    }
  }
}
