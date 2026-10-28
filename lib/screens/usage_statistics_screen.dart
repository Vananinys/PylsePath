import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/usage_statistics.dart';

class UsageStatisticsScreen extends StatefulWidget {
  const UsageStatisticsScreen({super.key, this.service});
  final UsageStatistics? service;
  @override
  State<UsageStatisticsScreen> createState() => _UsageStatisticsScreenState();
}

class _UsageStatisticsScreenState extends State<UsageStatisticsScreen> {
  late final service = widget.service ?? UsageStatistics.instance;
  bool _enabled = false, _loading = true, _busy = false;
  Map<String, int> _counts = {};
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await service.snapshot();
      if (mounted)
        setState(() {
          _enabled = data['enabled'] as bool;
          _counts = data['counts'] as Map<String, int>;
          _loading = false;
          _error = null;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = 'Не удалось прочитать локальные счётчики';
        });
    }
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    if (value) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Локальные счётчики'),
          content: const SingleChildScrollView(
            child: Text(UsageStatistics.consentText),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Не включать'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Разрешить локально'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      await service.setEnabled(value);
      await _load();
    } catch (_) {
      _message('Выбор не сохранён. Счётчики не считаются включёнными.');
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _preview() async {
    if (_busy) return;
    try {
      final report = await service.exportReport();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) => FractionallySizedBox(
          heightFactor: .85,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Что будет в отчёте',
                  style: Theme.of(ctx).textTheme.titleLarge,
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Автоматической отправки нет. Получатель может увидеть данные вашего аккаунта в выбранной программе отправки. Передавайте отчёт только если согласны.',
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(child: SelectableText(report)),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () async {
                    try {
                      await SharePlus.instance.share(
                        ShareParams(
                          text: report,
                          title: 'PulsePath: локальные счётчики',
                        ),
                      );
                    } catch (_) {
                      _message('Не удалось открыть программу отправки');
                    }
                  },
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Отправить этот отчёт…'),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (_) {
      _message('Не удалось подготовить отчёт');
    }
  }

  Future<void> _clear() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Очистить счётчики?'),
        content: const Text(
          'Будут очищены только локальные счётчики использования. Поездки и профиль сохранятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Очистить счётчики'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await service.clear();
      await _load();
    } catch (_) {
      _message('Не удалось очистить счётчики');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totals = <String, int>{};
    for (final entry in _counts.entries) {
      final event = entry.key.split('|').last;
      totals[event] = (totals[event] ?? 0) + entry.value;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Помочь улучшить PulsePath')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ваши данные остаются на телефоне',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Считаем использование разделов и результат записи: удалось ли построить маршрут, сохранить тренировку и восстановить GPS. Без координат, треков, переписки, фото и идентификатора аккаунта в отчёте. Срок — до 30 дней при использовании приложения.',
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Вести локальные счётчики'),
                      subtitle: const Text(
                        'Добровольно. По умолчанию выключено.',
                      ),
                      value: _enabled,
                      onChanged: _loading || _busy || _error != null
                          ? null
                          : _toggle,
                    ),
                  ],
                ),
              ),
            ),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) ...[
              Text(_error!),
              TextButton(onPressed: _load, child: const Text('Повторить')),
            ],
            const SizedBox(height: 12),
            Text(
              'За последние 30 дней',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (totals.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Счётчиков пока нет. Предыдущие действия не восстанавливаются задним числом.',
                ),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final event in UsageEvent.values)
                  if (totals.containsKey(event.name))
                    Chip(label: Text('${event.label}: ${totals[event.name]}')),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _busy || _loading || _error != null || _counts.isEmpty
                  ? null
                  : _preview,
              icon: const Icon(Icons.preview_outlined),
              label: const Text('Посмотреть и отправить отчёт'),
            ),
            TextButton(
              onPressed: _busy || _loading || _counts.isEmpty ? null : _clear,
              child: const Text('Очистить локальные счётчики'),
            ),
            const Text(
              'Отчёт отправляете только вы. У PulsePath пока нет сервера аналитики в России; фоновой отправки нет. Включение бета-канала не включает счётчики.',
            ),
          ],
        ),
      ),
    );
  }
}
