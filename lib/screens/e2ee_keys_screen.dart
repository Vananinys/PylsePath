import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/e2ee_identity_service.dart';

class E2eeKeysScreen extends StatefulWidget {
  const E2eeKeysScreen({super.key, required this.service, this.peer});
  final E2eeIdentityService service;
  final String? peer;
  @override
  State<E2eeKeysScreen> createState() => _KeysState();
}

class _KeysState extends State<E2eeKeysScreen> {
  static const _privacy = MethodChannel('pulsepath/privacy');
  final _input = TextEditingController();
  bool _busy = true, _ready = false;
  String? _error, _recovery;
  Map<String, String> _fingerprints = {};
  @override
  void initState() {
    super.initState();
    _privacy.invokeMethod('secureScreen', true).catchError((_) => null);
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.service.ensure();
      final own = await widget.service.fingerprints(null);
      if (!mounted) return;
      setState(() {
        _ready = true;
        _fingerprints = own;
        _error = null;
      });
      if (widget.peer != null) {
        final both = await widget.service.fingerprints(widget.peer);
        if (mounted) setState(() => _fingerprints = both);
      }
    } on E2eeException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Не удалось подготовить ключи. Проверьте соединение.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showRecovery() async {
    setState(() => _busy = true);
    try {
      final key = await widget.service.exportRecoveryKey();
      if (mounted) setState(() => _recovery = key);
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось прочитать ключ.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.restore(_input.text.trim());
      _input.clear();
      await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Ключ не подошёл или резервная копия недоступна. Существующие данные сохранены.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _recovery = null;
    _privacy.invokeMethod('secureScreen', false).catchError((_) => null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Ключи переписки')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'E2EE · экспериментальная бета',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Исходящий текст и стикеры этой беты шифруются на устройстве. Сервер хранит шифротекст и не получает личный ключ. Оба собеседника должны открыть новую UI Beta. Сообщения без замка не защищены E2EE.',
          ),
          const SizedBox(height: 8),
          const Text(
            'После первого защищённого сообщения открытая отправка в этот диалог блокируется и для старых версий. Старая история и системные карточки не становятся зашифрованными. Вложения и группы пока не подключены.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Сохраните личный ключ отдельно: он нужен для чтения переписки на другом телефоне. При его утрате сервер не сможет восстановить доступ. Сверьте отпечатки с собеседником по другому каналу: первый контакт доверяет полученному от сервера открытому ключу. Crypto_box не обеспечивает прямую секретность при утечке личного ключа.',
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_error!),
            ),
          for (final entry in _fingerprints.entries) ...[
            const SizedBox(height: 16),
            Text(
              entry.key == 'own'
                  ? 'Отпечаток моего ключа'
                  : 'Отпечаток собеседника',
            ),
            SelectableText(entry.value),
          ],
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _busy || !_ready ? null : _showRecovery,
            child: const Text('Показать личный ключ восстановления'),
          ),
          if (_recovery != null) ...[
            const Text(
              'Личный ключ — храните его у себя, не отправляйте собеседникам.',
            ),
            SelectableText(_recovery!),
          ],
          const SizedBox(height: 20),
          TextField(
            controller: _input,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: const InputDecoration(
              labelText: 'Личный ключ для восстановления',
            ),
          ),
          FilledButton(
            onPressed: _busy ? null : _restore,
            child: const Text('Восстановить на этом устройстве'),
          ),
        ],
      ),
    ),
  );
}
