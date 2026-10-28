import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import 'user_scope.dart';

class ChatLocalStore {
  ChatLocalStore(this.owner, this.friendId, {String? Function()? currentOwner})
    : _currentOwner = currentOwner ?? UserScope.currentUserId;
  final String? Function() _currentOwner;
  final String? owner;
  final String friendId;
  String get _key => UserScope.keyFor('chat_v1_$friendId', owner);
  Future<void> _tail = Future.value();

  Future<List<ChatMessage>> readMessages() async {
    if (_currentOwner() != owner) return [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final rows = jsonDecode(prefs.getString(_key) ?? '[]') as List;
      return rows
          .map(
            (row) => ChatMessage.fromRow(Map<String, dynamic>.from(row as Map)),
          )
          .where(
            (message) =>
                (message.senderId == owner && message.receiverId == friendId) ||
                (message.senderId == friendId && message.receiverId == owner),
          )
          .map(
            (message) => message.delivery == MessageDelivery.sending
                ? message.withDelivery(MessageDelivery.failed)
                : message,
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveMessages(List<ChatMessage> messages) {
    final pending = messages
        .where((m) => m.delivery != MessageDelivery.sent)
        .toList();
    final sent = messages
        .where((m) => m.delivery == MessageDelivery.sent)
        .toList();
    final kept = [
      ...sent.skip(sent.length > 200 ? sent.length - 200 : 0),
      ...pending,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final encoded = jsonEncode(kept.map((m) => m.toRow()).toList());
    _tail = _tail.catchError((Object _) {}).then((_) async {
      if (_currentOwner() != owner) return;
      final prefs = await SharedPreferences.getInstance();
      if (_currentOwner() != owner) return;
      if (!await prefs.setString(_key, encoded)) {
        throw StateError(
          'Не удалось сохранить очередь сообщений на устройстве',
        );
      }
    });
    return _tail;
  }

  Future<String> readDraft() async {
    if (_currentOwner() != owner) return '';
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('${_key}_draft') ?? '';
  }

  Future<void> saveDraft(String draft) {
    _tail = _tail.catchError((Object _) {}).then((_) async {
      if (_currentOwner() != owner) return;
      final prefs = await SharedPreferences.getInstance();
      if (draft.isEmpty) {
        await prefs.remove('${_key}_draft');
      } else {
        await prefs.setString('${_key}_draft', draft);
      }
    });
    return _tail;
  }
}
