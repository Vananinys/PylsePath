import 'package:flutter/material.dart';

import '../services/signal_diagnostic.dart';

class SignalTestScreen extends StatefulWidget {
  const SignalTestScreen({super.key, this.runDiagnostic = runSignalDiagnostic});
  final Future<List<String>> Function() runDiagnostic;
  @override
  State<SignalTestScreen> createState() => _SignalTestScreenState();
}

class _SignalTestScreenState extends State<SignalTestScreen> {
  bool _busy = false;
  List<String> _results = [];
  String? _error;
  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _results = [];
      _error = null;
    });
    try {
      final results = await widget.runDiagnostic();
      if (mounted) setState(() => _results = results);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error =
              'Проверка не завершена (${e.runtimeType}). Можно повторить и сообщить об ошибке.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Проверка Signal')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Новый движок шифрования · эксперимент',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        const Text(
          'Это локальная проверка нового Signal-движка на тестовых сообщениях Алисы и Боба. Обычные чаты пока используют прежнюю схему E2EE. Переход реальной переписки ещё не включён.',
        ),
        const SizedBox(height: 12),
        const Text(
          'Проверяются шифрование, ответ, повтор отправки, подмена пакета и чтение после повторного открытия хранилища. Тестовые ключи сохраняются отдельно от ключей вашей переписки.',
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _busy ? null : _run,
          icon: const Icon(Icons.science_outlined),
          label: Text(_busy ? 'Проверка…' : 'Запустить проверку'),
        ),
        if (_busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        for (final result in _results)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text('✓ $result'),
          ),
        if (_results.isNotEmpty) ...[
          const Divider(),
          const Text(
            'Локальная проверка завершена. Это не проверка доставки через сервер и не подтверждение перехода обычных чатов на Signal.',
          ),
        ],
      ],
    ),
  );
}
