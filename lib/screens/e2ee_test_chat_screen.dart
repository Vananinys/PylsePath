import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sodium/sodium.dart';

import '../data/e2ee_recovery_vault.dart';
import '../data/e2ee_secret_store.dart';
import '../data/user_scope.dart';
import '../services/e2ee_box_codec.dart';

/// Isolated local crypto experiment. Never sends to users or production tables.
class E2eeTestChatScreen extends StatefulWidget {
  const E2eeTestChatScreen({super.key});
  @override
  State<E2eeTestChatScreen> createState() => _TestChatState();
}

class _TestChatState extends State<E2eeTestChatScreen> {
  final _input = TextEditingController(text: 'Проверка шифрования');
  final _account = UserScope.currentUserId();
  final _messages = <Map<String, dynamic>>[];
  final _checks = <String>[];
  final _pairs = <String, KeyPair>{};
  Sodium? _sodium;
  String _sender = 'Алиса';
  String? _error;
  bool _busy = true;
  bool get _sameAccount => UserScope.currentUserId() == _account;
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  void _requireAccount() {
    if (!_sameAccount) {
      throw StateError('Аккаунт изменился. Откройте тест заново.');
    }
  }

  Future<void> _initialize() async {
    try {
      final sodium = await SodiumInit.init();
      for (final name in ['Алиса', 'Боб']) {
        final owner = 'e2ee-test:${_account ?? 'guest'}:$name';
        final store = E2eeSecretStore(
          owner: owner,
          currentOwner: () => _sameAccount ? owner : null,
        );
        final saved = await store.read();
        final seedBytes = saved == null
            ? sodium.randombytes.buf(sodium.crypto.box.seedBytes)
            : base64Url.decode(saved['seed'] as String);
        if (saved == null) {
          await store.save({'seed': base64UrlEncode(seedBytes)});
        }
        _requireAccount();
        final seed = sodium.secureCopy(seedBytes);
        seedBytes.fillRange(0, seedBytes.length, 0);
        try {
          final pair = sodium.crypto.box.seedKeyPair(seed);
          if (!mounted) {
            pair.secretKey.dispose();
            return;
          }
          _pairs[name] = pair;
        } finally {
          seed.dispose();
        }
      }
      if (mounted) {
        setState(() {
          _sodium = sodium;
          _busy = false;
        });
      }
      if (!mounted) return;
      await _selfTest();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Тест недоступен: ${e.runtimeType}';
        });
      }
    }
  }

  Map<String, dynamic> _seal(String id, String text) {
    _requireAccount();
    return E2eeBoxCodec(_sodium!).encrypt(
      id: id,
      sender: _sender,
      conversation: 'local-crypto-lab',
      senderSecret: _pairs[_sender]!.secretKey,
      recipients: {for (final e in _pairs.entries) e.key: e.value.publicKey},
      payload: {'body': text},
    );
  }

  Map<String, dynamic> _open(
    Map<String, dynamic> envelope,
    String id,
    String sender,
    String recipient, {
    String room = 'local-crypto-lab',
  }) {
    _requireAccount();
    return E2eeBoxCodec(_sodium!).decrypt(
      envelope: envelope,
      id: id,
      sender: sender,
      conversation: room,
      recipient: recipient,
      senderPublic: _pairs[sender]!.publicKey,
      recipientSecret: _pairs[recipient]!.secretKey,
    );
  }

  void _send() {
    try {
      final text = _input.text.trim();
      if (text.isEmpty || text.length > 4000 || _busy || _sodium == null) {
        return;
      }
      final id = '${DateTime.now().microsecondsSinceEpoch}-${_messages.length}';
      final recipient = _sender == 'Алиса' ? 'Боб' : 'Алиса';
      final envelope = _seal(id, text);
      final opened = _open(envelope, id, _sender, recipient);
      setState(() {
        _messages.add({
          'sender': _sender,
          'body': opened['body'],
          'envelope': envelope,
        });
        _error = null;
      });
      _input.clear();
    } catch (e) {
      setState(() => _error = 'Не отправлено: ${e.runtimeType}');
    }
  }

  Future<void> _selfTest() async {
    if (_sodium == null || _busy) return;
    setState(() {
      _busy = true;
      _checks.clear();
      _error = null;
    });
    try {
      void check(bool ok, String label) {
        if (!ok) throw StateError(label);
        _checks.add('✓ $label');
      }

      void rejects(void Function() action, String label) {
        var rejected = false;
        try {
          action();
        } catch (_) {
          rejected = true;
        }
        check(rejected, label);
      }

      final envelope = _seal('qa', 'Тестовая фраза');
      final other = _sender == 'Алиса' ? 'Боб' : 'Алиса';
      check(
        _open(envelope, 'qa', _sender, other)['body'] == 'Тестовая фраза',
        'Получатель расшифровал',
      );
      check(
        _open(envelope, 'qa', _sender, _sender)['body'] == 'Тестовая фраза',
        'Отправитель читает свою копию',
      );
      check(
        !jsonEncode(envelope).contains('Тестовая фраза'),
        'В конверте нет открытого текста',
      );
      rejects(
        () => _open(envelope, 'other', _sender, other),
        'Подмена ID отклонена',
      );
      rejects(
        () => _open(envelope, 'qa', _sender, other, room: 'other'),
        'Подмена диалога отклонена',
      );
      final packet = (envelope['recipients'] as Map)[other] as Map;
      final Uint8List bytes = base64Url.decode(packet['ciphertext'] as String);
      bytes[0] ^= 1;
      packet['ciphertext'] = base64UrlEncode(bytes);
      rejects(
        () => _open(envelope, 'qa', _sender, other),
        'Подмена шифротекста отклонена',
      );
      final vault = E2eeRecoveryVault();
      final key = await vault.createRecoveryKey();
      final backup = await vault.seal(
        owner: 'local-test',
        recoveryKey: key,
        secrets: {'fixture': 'test-only'},
      );
      check(
        (await E2eeRecoveryVault().open(
              owner: 'local-test',
              recoveryKey: key,
              envelope: backup,
            ))['fixture'] ==
            'test-only',
        'Контейнер восстановления прочитан',
      );
      var wrongKeyRejected = false;
      try {
        await vault.open(
          owner: 'local-test',
          recoveryKey: await vault.createRecoveryKey(),
          envelope: backup,
        );
      } catch (_) {
        wrongKeyRejected = true;
      }
      check(wrongKeyRejected, 'Неверный ключ восстановления отклонён');
      _requireAccount();
      debugPrint('E2EE_BETA_QA: ${_checks.length} checks passed');
    } catch (e) {
      _error = 'Проверка не прошла: ${e.runtimeType}';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    for (final pair in _pairs.values) {
      pair.secretKey.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Тест шифрования')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Локальный тестовый чат',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Алиса и Боб — два тестовых участника на этом телефоне. Сервер и реальные переписки не используются. Этот тест ещё не подтверждает шифрование обычных чатов.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Схема: libsodium crypto_box. Прямой секретности прошлых сообщений при утечке личного ключа нет.',
          ),
          const SizedBox(height: 12),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Wrap(
            spacing: 8,
            children: [
              for (final who in ['Алиса', 'Боб'])
                ChoiceChip(
                  label: Text(who),
                  selected: _sender == who,
                  onSelected: _busy
                      ? null
                      : (_) => setState(() => _sender = who),
                ),
            ],
          ),
          TextField(
            controller: _input,
            maxLength: 4000,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Только тестовые фразы',
            ),
          ),
          FilledButton.icon(
            onPressed: _busy || _sodium == null ? null : _send,
            icon: const Icon(Icons.lock_outline),
            label: const Text('Зашифровать и прочитать'),
          ),
          for (final message in _messages)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${message['sender']}: ${message['body']}'),
                    const Text('Получатель расшифровал на устройстве'),
                    ExpansionTile(
                      title: const Text('Зашифрованный конверт'),
                      children: [
                        SelectableText(jsonEncode(message['envelope'])),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _busy || _sodium == null ? null : _selfTest,
            child: const Text('Повторить проверки защиты'),
          ),
          for (final result in _checks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(result),
            ),
        ],
      ),
    ),
  );
}
