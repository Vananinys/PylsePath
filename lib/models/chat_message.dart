import 'shared_route.dart';

enum MessageDelivery { sending, failed, sent }

/// Сообщение личного чата (таблица `chat_messages`).
///
/// Сообщение содержит либо текст ([body]), либо стикер ([sticker]),
/// либо и то и другое.
class ChatMessage {
  final Map<String, dynamic>? groupInvitation;
  final SharedRoute? routeAttachment;
  final MessageDelivery delivery;
  final String? photoReference;
  final String? audioReference;
  final DateTime? editedAt;
  final String id;
  final String senderId;
  final String receiverId;
  final String? body;
  final String? sticker;
  final String? photoUrl;

  /// Голосовое сообщение: URL в Storage и длительность в секундах.
  final String? audioUrl;
  final int? audioSeconds;

  final DateTime createdAt;
  final DateTime? readAt;

  /// Ответ (цитирование): id сообщения, на которое отвечаем.
  final String? replyToId;

  /// Реакции: emoji -> список id пользователей, поставивших её.
  final Map<String, List<String>> reactions;

  const ChatMessage({
    this.groupInvitation,
    this.routeAttachment,
    this.delivery = MessageDelivery.sent,
    this.photoReference,
    this.audioReference,
    this.editedAt,
    required this.id,
    required this.senderId,
    required this.receiverId,
    this.body,
    this.sticker,
    this.photoUrl,
    this.audioUrl,
    this.audioSeconds,
    required this.createdAt,
    this.readAt,
    this.replyToId,
    this.reactions = const {},
  });

  bool get isStickerOnly =>
      groupInvitation == null &&
      routeAttachment == null &&
      (body == null || body!.trim().isEmpty) &&
      sticker != null &&
      sticker!.isNotEmpty;

  bool get isVoice => audioUrl != null && audioUrl!.isNotEmpty;

  bool get isPhoto => photoUrl != null && photoUrl!.isNotEmpty;

  bool get isRead => readAt != null;

  ChatMessage copyWith({MessageDelivery? delivery, DateTime? readAt}) =>
      ChatMessage(
        id: id,
        senderId: senderId,
        receiverId: receiverId,
        body: body,
        sticker: sticker,
        photoUrl: photoUrl,
        audioUrl: audioUrl,
        audioSeconds: audioSeconds,
        createdAt: createdAt,
        readAt: readAt ?? this.readAt,
        replyToId: replyToId,
        reactions: reactions,
        delivery: delivery ?? this.delivery,
        photoReference: photoReference,
        audioReference: audioReference,
        editedAt: editedAt,
        routeAttachment: routeAttachment,
        groupInvitation: groupInvitation,
      );
  ChatMessage withDelivery(MessageDelivery value) => copyWith(delivery: value);

  Map<String, dynamic> toRow() => {
    'group_invitation': groupInvitation,
    'route_attachment': routeAttachment?.toJson(),
    'id': id,
    'sender_id': senderId,
    'receiver_id': receiverId,
    'body': body,
    'sticker': sticker,
    'photo_url': photoReference ?? photoUrl,
    'audio_url': audioReference ?? audioUrl,
    'audio_seconds': audioSeconds,
    'created_at': createdAt.toUtc().toIso8601String(),
    'read_at': readAt?.toUtc().toIso8601String(),
    'reply_to_id': replyToId,
    'reactions': reactions,
    'edited_at': editedAt?.toUtc().toIso8601String(),
    'delivery_status': delivery.name,
  };

  factory ChatMessage.fromRow(Map<String, dynamic> row) {
    return ChatMessage(
      groupInvitation: row['group_invitation'] is Map
          ? Map<String, dynamic>.from(row['group_invitation'] as Map)
          : null,
      routeAttachment: SharedRoute.tryParse(row['route_attachment']),
      delivery:
          MessageDelivery.values
              .where((value) => value.name == row['delivery_status'])
              .firstOrNull ??
          MessageDelivery.sent,
      photoReference: row['photo_reference'] as String?,
      audioReference: row['audio_reference'] as String?,
      editedAt: DateTime.tryParse(row['edited_at'] as String? ?? ''),
      id: (row['id'] ?? '').toString(),
      senderId: (row['sender_id'] ?? '').toString(),
      receiverId: (row['receiver_id'] ?? '').toString(),
      body: row['body'] as String?,
      sticker: row['sticker'] as String?,
      photoUrl: row['photo_url'] as String?,
      audioUrl: row['audio_url'] as String?,
      audioSeconds: row['audio_seconds'] as int?,
      createdAt:
          DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
      readAt: row['read_at'] == null
          ? null
          : DateTime.tryParse(row['read_at'] as String),
      replyToId:
          row['reply_to_id'] == null || row['reply_to_id'].toString().isEmpty
          ? null
          : row['reply_to_id'].toString(),
      reactions: _reactionsFromRow(row['reactions']),
    );
  }

  static Map<String, List<String>> _reactionsFromRow(dynamic raw) {
    if (raw is! Map) return const {};
    final result = <String, List<String>>{};
    for (final entry in raw.entries) {
      final users = (entry.value as List? ?? const [])
          .map((id) => id.toString())
          .toList();
      if (users.isNotEmpty) result[entry.key.toString()] = users;
    }
    return result;
  }
}
