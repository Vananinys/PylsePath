import 'dart:convert';

import '../config/app_variant.dart';
import 'e2ee_secret_store.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import 'user_scope.dart';
import 'local_data_integrity.dart';

class ChatLocalStore {
  ChatLocalStore(this.owner, this.friendId, {String? Function()? currentOwner})
    : _currentOwner = currentOwner ?? UserScope.currentUserId;
  final String? Function() _currentOwner;
  final String? owner;
  final String friendId;
  String get _key => UserScope.keyFor('chat_v1_$friendId', owner);
  String get _recoveryKey => '${_key}_recovery_v1';
  bool get _protected => AppVariant.e2eeMessaging && owner != null;
  E2eeSecretStore get _secure {
    final keyOwner = 'chat-cache:$owner:$friendId';
    return E2eeSecretStore(
      owner: keyOwner,
      currentOwner: () => _currentOwner() == owner ? keyOwner : null,
    );
  }

  Future<void> _tail = Future.value();
  String? recoveryNotice;
  void _requireOwner() {
    if (_currentOwner() != owner)
      throw StateError('Аккаунт чата изменился. Откройте диалог заново.');
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final future = _tail.then((_) => operation());
    _tail = future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return future;
  }

  List<ChatMessage> _decode(String raw) => (jsonDecode(raw) as List)
      .map((row) => ChatMessage.fromRow(Map<String, dynamic>.from(row as Map)))
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

  /// Recovery is a separate writable archive; damaged primary bytes stay intact.
  Future<String> _archive(SharedPreferences prefs) async {
    recoveryNotice = null;
    final recovery = prefs.getString(_recoveryKey);
    if (recovery != null) {
      try {
        _decode(recovery);
      } catch (_) {
        await LocalDataIntegrity.preserve(prefs, _recoveryKey, recovery);
        throw const FormatException(
          'Дополнительная очередь повреждена. Оригинал сохранён; запись заблокирована.',
        );
      }
      recoveryNotice = 'Прежняя локальная очередь сохранена отдельно. Новые сообщения сохраняются в дополнительном архиве.';
      return _recoveryKey;
    }
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        _decode(raw);
      } catch (_) {
        await LocalDataIntegrity.preserve(prefs, _key, raw);
        recoveryNotice = 'Не удалось прочитать прежнюю очередь. Оригинал сохранён; новые сообщения будут сохраняться отдельно.';
        return _recoveryKey;
      }
    }
    return _key;
  }

  Future<List<ChatMessage>> readMessages() => _serial(() async {
    _requireOwner();
    if (_protected) {
      final cache = await _secure.read();
      _requireOwner();
      if (cache?['messages'] is List)
        return _decode(jsonEncode(cache!['messages']));
    }
    final prefs = await SharedPreferences.getInstance();
    _requireOwner();
    final key = await _archive(prefs);
    _requireOwner();
    final raw = prefs.getString(key);
    return raw == null ? [] : _decode(raw);
  });

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
    return _serial(() async {
      _requireOwner();
      if (_protected) {
        final previous = await _secure.read() ?? <String, dynamic>{};
        final priorRows = {
          for (final row in (previous['messages'] as List? ?? []))
            if (row is Map) row['id']: row,
        };
        await _secure.save({
          ...previous,
          'messages': kept
              .map(
                (m) => {
                  ...?priorRows[m.id],
                  ...m.toRow(),
                  'e2ee_encrypted': m.isEncrypted,
                  'e2ee_failed': m.decryptionFailed,
                },
              )
              .toList(),
        });
        _requireOwner();
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      _requireOwner();
      final key = await _archive(prefs);
      final raw = prefs.getString(key);
      if (raw != null) {
        final rows = jsonDecode(raw) as List;
        // Preserve unknown fields without backing up deliberately refreshed URLs.
        if (rows.any(
          (row) => LocalDataIntegrity.unknownKeys(
            row as Map,
            ChatMessage.fromRow(Map<String, dynamic>.from(row))
                .toRow()
                .keys
                .toSet(),
          ),
        )) {
          await LocalDataIntegrity.preserve(prefs, key, raw);
        }
      }
      _requireOwner();
      if (!await prefs.setString(key, encoded))
        throw StateError(
          'Не удалось сохранить очередь сообщений на устройстве',
        );
    });
  }

  Future<String> readDraft() => _serial(() async {
    _requireOwner();
    if (_protected) {
      final cache = await _secure.read();
      _requireOwner();
      if (cache?['draft'] is String) return cache!['draft'] as String;
    }
    final prefs = await SharedPreferences.getInstance();
    _requireOwner();
    return prefs.getString('${_key}_draft') ?? '';
  });
  Future<void> saveDraft(String draft) => _serial(() async {
    _requireOwner();
    if (_protected) {
      final previous = await _secure.read() ?? <String, dynamic>{};
      await _secure.save({...previous, 'draft': draft});
      _requireOwner();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    _requireOwner();
    final ok = draft.isEmpty
        ? await prefs.remove('${_key}_draft')
        : await prefs.setString('${_key}_draft', draft);
    if (!ok) throw StateError('Не удалось сохранить черновик сообщения');
  });
}
