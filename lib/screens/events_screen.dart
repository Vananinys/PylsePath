import 'package:flutter/material.dart';

import '../services/events_service.dart';
import '../data/user_scope.dart';

class EventsScreen extends StatefulWidget {
  const EventsScreen({super.key, this.service});
  final EventsService? service;
  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  late final _service = widget.service ?? EventsService();
  late final String? _owner = UserScope.currentUserId();
  Map<String, dynamic>? _data;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _current => mounted && _owner == UserScope.currentUserId();
  Future<void> _load() async {
    try {
      final data = await _service.call('list');
      if (_current)
        setState(() {
          _data = data;
          _error = null;
        });
    } catch (_) {
      if (mounted)
        setState(
          () => _error =
              'Не удалось загрузить события. Проверьте интернет и аккаунт.',
        );
    }
  }

  Future<void> _action(String action, Map<String, dynamic> data) async {
    if (_busy || !_current) return;
    setState(() => _busy = true);
    try {
      final result = await _service.call(action, data);
      if (!mounted || !_current) return;
      if (action == 'claim') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result['earned'] == true
                  ? 'Награда получена! Повторная проверка не начисляет опыт заново.'
                  : 'Прогресс: ${result['progress']} / ${result['target']}. Сначала синхронизируйте тренировки.',
            ),
          ),
        );
      }
      if (action == 'results') {
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Результаты опроса'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ответов: ${result['answers']}\nУдобство: ${result['usability'] ?? '—'} / 5\nПолезность: ${result['usefulness'] ?? '—'} / 5',
                  ),
                  for (final row in result['feedback'] as List? ?? [])
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text('${row['favorite']}\n${row['suggestion']}'),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Закрыть'),
              ),
            ],
          ),
        );
      }
      await _load();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Действие не выполнено. Проверьте права, сроки и интернет.',
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<String, String>?> _fields(
    String title,
    Map<String, String> labels,
  ) async {
    final values = {for (final entry in labels.entries) entry.key: ''};
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in labels.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    onChanged: (text) => values[entry.key] = text,
                    maxLength:
                        entry.key == 'description' || entry.key == 'suggestion'
                        ? 1000
                        : 100,
                    decoration: InputDecoration(labelText: entry.value),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, {
              for (final entry in values.entries) entry.key: entry.value.trim(),
            }),
            child: const Text('Продолжить'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _feedback(Map<String, dynamic> event) async {
    final fields = await _fields('Ваше мнение о PulsePath', {
      'usability': 'Удобство от 1 до 5',
      'usefulness': 'Полезность от 1 до 5',
      'favorite': 'Какая функция полезнее всего?',
      'suggestion': 'Что неудобно или чего не хватает?',
    });
    if (fields == null || !mounted || !_current) return;
    final a = int.tryParse(fields['usability']!),
        b = int.tryParse(fields['usefulness']!);
    if (a == null ||
        b == null ||
        a < 1 ||
        a > 5 ||
        b < 1 ||
        b > 5 ||
        fields['favorite']!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Укажите две оценки 1–5 и полезную функцию.'),
        ),
      );
      return;
    }
    await _action('feedback', {
      'event_id': event['id'],
      ...fields,
      'usability': a,
      'usefulness': b,
    });
  }

  Future<void> _create() async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in {
              'event': 'Событие',
              'challenge': 'Челлендж',
              'beta': 'Бета-тест с опросом',
            }.entries)
              ListTile(
                title: Text(item.value),
                onTap: () => Navigator.pop(c, item.key),
              ),
          ],
        ),
      ),
    );
    if (kind == null || !_current) return;
    final fields = await _fields(
      'Создать ${kind == 'challenge' ? 'челлендж' : 'событие'}',
      {
        'title': 'Название',
        'description': 'Описание и условия',
        'days': 'Длительность, дней (1–90)',
        if (kind == 'challenge')
          'target': 'Количество тренировок (после вступления)',
        if (_data?['owner'] == true)
          'xp': 'Опыт за выполнение (0–500, пусто — 50)',
        if (_data?['owner'] == true)
          'badge': 'Название награды (необязательно)',
      },
    );
    if (fields == null || !_current) return;
    final days = int.tryParse(fields['days']!) ?? 0;
    final target = kind == 'challenge'
        ? int.tryParse(fields['target']!) ?? 0
        : 1;
    if (days < 1 || days > 90 || target < 1 || fields['title']!.length < 3)
      return;
    final now = DateTime.now().toUtc();
    await _action('create', {
      'kind': kind,
      'title': fields['title'],
      'description': fields['description'],
      'starts_at': now.toIso8601String(),
      'ends_at': now.add(Duration(days: days)).toIso8601String(),
      'metric': kind == 'challenge' ? 'rides' : 'feedback',
      'target': target,
      'xp': (int.tryParse(fields['xp'] ?? '') ?? 50).clamp(0, 500),
      'badge': (fields['badge'] ?? '').isNotEmpty
          ? fields['badge']
          : kind == 'beta'
          ? 'Исследователь PulsePath'
          : 'Участник PulsePath',
    });
  }

  Future<void> _role() async {
    final fields = await _fields('Ограниченные роли', {
      'user_id': 'UUID аккаунта пользователя',
    });
    if (fields == null || !mounted || !_current) return;
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(fields['user_id']!)) return;
    final choice = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final role in {
              'creator': 'Организатор',
              'moderator': 'Модератор',
            }.entries)
              for (final enabled in [true, false])
                ListTile(
                  title: Text(
                    '${enabled ? 'Назначить' : 'Снять'}: ${role.value}',
                  ),
                  onTap: () =>
                      Navigator.pop(c, {'role': role.key, 'enabled': enabled}),
                ),
          ],
        ),
      ),
    );
    if (choice != null) await _action('role', {...fields, ...choice});
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('События и челленджи'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: data?['creator'] == true
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.add),
              label: const Text('Создать'),
            )
          : null,
      body: !_current
          ? const Center(
              child: Text('Аккаунт изменился. Откройте раздел заново.'),
            )
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  TextButton(onPressed: _load, child: const Text('Повторить')),
                ],
              ),
            )
          : data == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${data['xp']} XP',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const Text(
                            'Опыт за выполненные челленджи и участие. Награда выдаётся один раз.',
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final reward
                                  in data['rewards'] as List? ?? [])
                                Chip(
                                  avatar: const Icon(
                                    Icons.workspace_premium,
                                    size: 18,
                                  ),
                                  label: Text(reward['badge'].toString()),
                                ),
                            ],
                          ),
                          if (data['owner'] == true)
                            TextButton.icon(
                              onPressed: _busy ? null : _role,
                              icon: const Icon(Icons.manage_accounts),
                              label: const Text(
                                'Назначить организатора или модератора',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Опрос добровольный. Не указывайте адреса, контакты и другие личные данные. Ответы видят организатор и владелец приложения.',
                    ),
                  ),
                  if ((data['items'] as List).isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Скоро здесь появятся новые события.'),
                    ),
                  for (final raw in data['items'] as List)
                    _card(Map<String, dynamic>.from(raw as Map)),
                ],
              ),
            ),
    );
  }

  Widget _card(Map<String, dynamic> event) {
    final active =
        DateTime.tryParse(event['ends_at'].toString())
            ?.isAfter(DateTime.now()) ==
        true;
    final joined = event['joined'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  event['kind'] == 'challenge'
                      ? Icons.emoji_events_outlined
                      : Icons.event_outlined,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    event['title'].toString(),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(event['description'].toString()),
            const SizedBox(height: 12),
            Text('${event['xp']} XP · ${event['badge']}'),
            Text(
              'До ${DateTime.parse(event['ends_at']).toLocal().toString().substring(0, 16)}',
            ),
            if (event['kind'] == 'challenge')
              Text(
                'Цель: ${event['target']} тренировок после вступления. Сначала синхронизируйте поездки.',
              ),
            Wrap(
              spacing: 8,
              children: [
                if (!joined && active)
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _action('join', {'event_id': event['id']}),
                    child: const Text('Участвовать'),
                  ),
                if (joined && active)
                  OutlinedButton(
                    onPressed: _busy ? null : () => _feedback(event),
                    child: const Text('Пройти опрос'),
                  ),
                if (joined && active)
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _action('claim', {'event_id': event['id']}),
                    child: Text(
                      event['earned'] == true
                          ? 'Награда получена'
                          : 'Проверить прогресс',
                    ),
                  ),
                if (_data?['owner'] == true || event['creator_id'] == _owner)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _action('results', {'event_id': event['id']}),
                    child: const Text('Ответы'),
                  ),
                if (_data?['owner'] == true ||
                    _data?['moderator'] == true ||
                    event['creator_id'] == _owner)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: const Text('Завершить событие?'),
                                content: const Text(
                                  'Оно исчезнет из активных. Полученные награды сохранятся.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c, false),
                                    child: const Text('Отмена'),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(c, true),
                                    child: const Text('Завершить'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true)
                              await _action('archive', {
                                'event_id': event['id'],
                              });
                          },
                    child: const Text('Завершить'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
