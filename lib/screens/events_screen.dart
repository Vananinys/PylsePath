import 'package:flutter/material.dart';

import '../services/events_service.dart';
import '../data/user_scope.dart';
import '../widgets/section_intro.dart';
import '../widgets/event_overview_card.dart';

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
  int _filter = 0;
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
    final form = GlobalKey<FormState>();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (labels.containsKey('usability'))
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Опрос добровольный. Не указывайте контакты, адреса и другие личные данные. Ответы видят организатор и владелец приложения.',
                    ),
                  ),
                for (final entry in labels.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: entry.key == 'usability' || entry.key == 'usefulness'
                        ? DropdownButtonFormField<int>(
                            isExpanded: true,
                            decoration: InputDecoration(labelText: entry.value),
                            items: [
                              for (var n = 1; n <= 5; n++)
                                DropdownMenuItem(
                                  value: n,
                                  child: Text('$n из 5'),
                                ),
                            ],
                            onChanged: (v) => values[entry.key] = '$v',
                            validator: (v) =>
                                v == null ? 'Выберите оценку' : null,
                          )
                        : TextFormField(
                            validator: (raw) {
                              final text = (raw ?? '').trim();
                              final number = int.tryParse(text);
                              if (entry.key == 'title' && text.length < 3)
                                return 'Введите не меньше 3 символов';
                              if (entry.key == 'days' &&
                                  (number == null || number < 1 || number > 90))
                                return 'От 1 до 90 дней';
                              if (entry.key == 'target' &&
                                  (number == null || number < 1))
                                return 'Укажите число тренировок от 1';
                              if (entry.key == 'xp' &&
                                  text.isNotEmpty &&
                                  (number == null ||
                                      number < 0 ||
                                      number > 500))
                                return 'От 0 до 500 XP';
                              if (entry.key == 'favorite' && text.isEmpty)
                                return 'Расскажите о полезной функции';
                              if (entry.key == 'user_id' &&
                                  !RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(text))
                                return 'Введите UUID аккаунта';
                              return null;
                            },
                            keyboardType:
                                ['days', 'target', 'xp'].contains(entry.key)
                                ? TextInputType.number
                                : TextInputType.multiline,
                            minLines:
                                entry.key == 'description' ||
                                    entry.key == 'suggestion'
                                ? 3
                                : 1,
                            maxLines:
                                entry.key == 'description' ||
                                    entry.key == 'suggestion'
                                ? 5
                                : 1,
                            onChanged: (text) => values[entry.key] = text,
                            maxLength:
                                entry.key == 'description' ||
                                    entry.key == 'suggestion'
                                ? 1000
                                : 100,
                            decoration: InputDecoration(labelText: entry.value),
                          ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState?.validate() != true) return;
              Navigator.pop(c, {
                for (final entry in values.entries)
                  entry.key: entry.value.trim(),
              });
            },
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
    final all = (data?['items'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final shown = all
        .where(
          (e) => switch (_filter) {
            1 => e['joined'] == true,
            2 => EventOverviewCard.ended(e) || e['earned'] == true,
            _ => !EventOverviewCard.ended(e) && e['earned'] != true,
          },
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('События и челленджи'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
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
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off_outlined, size: 48),
                    const SizedBox(height: 16),
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(
                      onPressed: _load,
                      child: const Text('Повторить'),
                    ),
                  ],
                ),
              ),
            )
          : data == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
                children: [
                  SectionIntro(
                    icon: Icons.emoji_events_outlined,
                    eyebrow: 'СООБЩЕСТВО PULSEPATH',
                    title: 'Выберите событие',
                    description: 'Выберите событие, выполните условия и получите награду. Участие добровольное.',
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Chip(
                            avatar: const Icon(
                              Icons.auto_awesome_outlined,
                              size: 18,
                            ),
                            label: Text('${data['xp'] ?? 0} XP получено'),
                          ),
                          Chip(
                            avatar: const Icon(Icons.people_outline, size: 18),
                            label: Text(
                              'Участвуете: ${all.where((e) => e['joined'] == true && !EventOverviewCard.ended(e)).length}',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final item in [
                        (0, 'Доступные'),
                        (1, 'Моё участие'),
                        (2, 'Завершённые'),
                      ])
                        ChoiceChip(
                          label: Text(item.$2),
                          selected: _filter == item.$1,
                          onSelected: (_) => setState(() => _filter = item.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (shown.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Icon(
                              _filter == 1
                                  ? Icons.bookmark_border
                                  : Icons.event_note_outlined,
                              size: 40,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _filter == 1
                                  ? 'Вы пока не участвуете в событиях'
                                  : _filter == 2
                                  ? 'Завершённых событий пока нет'
                                  : 'Новых событий пока нет',
                              style: Theme.of(context).textTheme.titleMedium,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _filter == 1
                                  ? 'Откройте «Доступные» и выберите то, что интересно.'
                                  : 'Потяните список вниз, чтобы обновить события.',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  for (final event in shown) _card(event),
                  if ((data['rewards'] as List? ?? []).isNotEmpty)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Полученные награды'),
                      children: [
                        for (final reward in data['rewards'] as List)
                          ListTile(
                            leading: const Icon(
                              Icons.workspace_premium_outlined,
                            ),
                            title: Text('${reward['badge']}'),
                            subtitle: Text('${reward['xp'] ?? 0} XP'),
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
    );
  }

  Widget _card(Map<String, dynamic> event) => EventOverviewCard(
    event: event,
    busy: _busy,
    onJoin: () => _action('join', {'event_id': event['id']}),
    onFeedback: () => _feedback(event),
    onClaim: () => _action('claim', {'event_id': event['id']}),
    onResults:
        _data?['owner'] == true ||
            (_owner != null && event['creator_id'] == _owner)
        ? () => _action('results', {'event_id': event['id']})
        : null,
    onArchive:
        _data?['owner'] == true ||
            _data?['moderator'] == true ||
            (_owner != null && event['creator_id'] == _owner)
        ? () => _archive(event)
        : null,
  );

  Future<void> _archive(Map<String, dynamic> event) async {
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
    if (confirmed == true && _current)
      await _action('archive', {'event_id': event['id']});
  }
}
