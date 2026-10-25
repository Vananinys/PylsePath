import 'dart:async';

import 'package:flutter/material.dart';

import '../services/owner_service.dart';

class OwnerAwardManagement extends StatefulWidget {
  const OwnerAwardManagement({super.key});
  @override
  State<OwnerAwardManagement> createState() => _OwnerAwardManagementState();
}

class _OwnerAwardManagementState extends State<OwnerAwardManagement> {
  final _service = OwnerService();
  final _search = TextEditingController(), _reason = TextEditingController();
  Timer? _debounce;
  int _searchRequest = 0, _awardsRequest = 0, _total = 0;
  bool _loading = true, _busy = false, _all = false;
  String? _error, _recipient;
  int _choice = 0;
  String _kind = 'achievement';
  List<Map<String, dynamic>> _users = [], _choices = [], _awards = [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final titles = await _service.titles();
      final achievements = await _service.catalog();
      final builtins = await _service.builtinAwards();
      _choices = [
        for (final row in titles) {...row, 'kind': 'title', 'key': row['id']},
        for (final item in achievements)
          {
            ...item.row,
            'kind': 'achievement',
            'key': 'catalog:${item.row['id']}',
          },
        ...builtins,
      ];
      final first = _choices.indexWhere((row) => row['kind'] == _kind);
      _choice = first >= 0 ? first : 0;
      await _findUsers('');
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = 'Не удалось загрузить пользователей и каталог. Повторите загрузку.';
        });
    }
  }

  Future<void> _findUsers(String text) async {
    final request = ++_searchRequest;
    try {
      final users = await _service.rewardUsers(text.trim());
      if (!mounted || request != _searchRequest) return;
      setState(() {
        _users = users;
        if (users.isNotEmpty)
          _total = (users.first['total_count'] as num).toInt();
        if (!users.any((u) => u['id'] == _recipient))
          _recipient = users.firstOrNull?['id'] as String?;
        _error = null;
      });
      await _loadAwards();
    } catch (_) {
      if (mounted && request == _searchRequest)
        setState(
          () => _error = 'Не удалось найти пользователей. Проверьте интернет.',
        );
    }
  }

  Future<void> _loadAwards() async {
    final request = ++_awardsRequest;
    final id = _recipient;
    if (id == null) {
      if (mounted) setState(() => _awards = []);
      return;
    }
    try {
      final rows = await _service.recipientAwards(id);
      if (mounted && request == _awardsRequest) setState(() => _awards = rows);
    } catch (_) {
      if (mounted && request == _awardsRequest)
        setState(() => _error = 'Не удалось загрузить награды пользователя.');
    }
  }

  String get _recipientName =>
      _users.where((u) => u['id'] == _recipient).firstOrNull?['username']
          as String? ??
      'Пользователь';
  Future<void> _manage(String action, {Map<String, dynamic>? award}) async {
    if (award == null &&
        (_choice >= _choices.length || _choices[_choice]['kind'] != _kind))
      return;
    if (_busy ||
        (_recipient == null && !_all) ||
        (_choices.isEmpty && award == null))
      return;
    final item = award ?? _choices[_choice];
    final recipient = _recipient;
    final reason = _reason.text.trim();
    final all = award == null && _all;
    final label = (item['title'] ?? item['label']) as String;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          action == 'grant' ? 'Выдать награду?' : 'Отозвать награду?',
        ),
        content: Text(
          '${item['icon']} $label\n\n${all ? 'Получатели: все $_total пользователей, зарегистрированных сейчас.' : 'Получатель: $_recipientName.'}\n\n${action == 'grant' ? 'Повторная выдача не создаёт копий. Титул появится в коллекции — человек сам решит, показывать ли его.' : 'Будет удалена только выбранная награда владельца. Достижения за тренировки сохранятся.'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(action == 'grant' ? 'Выдать' : 'Отозвать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final count = await _service.manageRecipients(
        action: action,
        kind: item['kind'] as String,
        key: (item['key'] ?? item['award_key']) as String,
        userId: all ? null : recipient,
        all: all,
        reason: reason,
      );
      await _loadAwards();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              count == 0
                  ? 'Изменений нет: награда уже выдана или отсутствует.'
                  : '${action == 'grant' ? 'Выдано' : 'Отозвано'} наград: $count',
            ),
          ),
        );
    } catch (_) {
      if (mounted)
        setState(
          () => _error = 'Не удалось изменить награды. Проверьте права владельца и интернет.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _history() async {
    try {
      final rows = await _service.awardHistory();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (c) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(c).height * .7,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'История выдачи',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                if (rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Выдач пока нет.'),
                  ),
                for (final row in rows)
                  ListTile(
                    leading: Icon(
                      row['action'] == 'grant'
                          ? Icons.card_giftcard
                          : Icons.undo,
                    ),
                    title: Text(
                      '${row['award_label'] ?? 'Награда'} · ${row['action'] == 'grant' ? 'выдано' : 'отозвано'}: ${row['affected']}',
                    ),
                    subtitle: Text(
                      '${row['kind'] == 'title' ? 'Титул' : 'Достижение'} · ${row['all_users'] == true ? 'Все пользователи' : row['recipient_name'] ?? 'Пользователь'}\n${DateTime.tryParse(row['created_at'].toString())?.toLocal().toString().substring(0, 16) ?? ''}${(row['reason'] as String).isEmpty ? '' : '\n${row['reason']}'}',
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Не удалось загрузить историю выдачи.');
    }
  }

  @override
  Widget build(BuildContext context) => _loading
      ? const Center(child: CircularProgressIndicator())
      : AbsorbPointer(
          absorbing: _busy,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Выдача наград',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'История выдачи',
                    onPressed: _history,
                    icon: const Icon(Icons.history),
                  ),
                ],
              ),
              const Text(
                'Каталог общий для приложения. Выбирайте получателя перед выдачей.',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Всем пользователям ($_total)'),
                subtitle: const Text(
                  'Только существующим аккаунтам. Выдача требует подтверждения.',
                ),
                value: _all,
                onChanged: (v) => setState(() => _all = v),
              ),
              if (!_all) ...[
                TextField(
                  controller: _search,
                  maxLength: 80,
                  decoration: const InputDecoration(
                    labelText: 'Найти пользователя по имени',
                    prefixIcon: Icon(Icons.search),
                    counterText: '',
                  ),
                  onChanged: (v) {
                    _debounce?.cancel();
                    _debounce = Timer(
                      const Duration(milliseconds: 350),
                      () => _findUsers(v),
                    );
                  },
                ),
                const SizedBox(height: 12),
                if (_users.isEmpty) const Text('Пользователи не найдены.'),
                if (_users.isNotEmpty)
                  DropdownButtonFormField<String>(
                    key: ValueKey(_recipient),
                    initialValue: _recipient,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Получатель'),
                    items: [
                      for (final u in _users)
                        DropdownMenuItem(
                          value: u['id'] as String,
                          child: Text(
                            '${u['username'] ?? 'Без имени'} · ${(u['id'] as String).substring(0, 6)}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      setState(() {
                        _recipient = v;
                        _awards = [];
                      });
                      _loadAwards();
                    },
                  ),
              ],
              const SizedBox(height: 20),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'achievement',
                    icon: Icon(Icons.emoji_events_outlined),
                    label: Text('Достижения'),
                  ),
                  ButtonSegment(
                    value: 'title',
                    icon: Icon(Icons.badge_outlined),
                    label: Text('Титулы'),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (v) => setState(() {
                  _kind = v.first;
                  final first = _choices.indexWhere(
                    (row) => row['kind'] == _kind,
                  );
                  if (first >= 0) _choice = first;
                }),
              ),
              const SizedBox(height: 12),
              if (_choices.any((row) => row['kind'] == _kind))
                DropdownButtonFormField<int>(
                  key: ValueKey('$_kind:$_choice'),
                  initialValue: _choice,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Награда из каталога',
                  ),
                  items: [
                    for (var i = 0; i < _choices.length; i++)
                      if (_choices[i]['kind'] == _kind)
                        DropdownMenuItem(
                          value: i,
                          child: Text(
                            '${_choices[i]['kind'] == 'title' ? 'Титул' : 'Достижение'} · ${_choices[i]['icon']} ${_choices[i]['title']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                  ],
                  onChanged: (v) => setState(() => _choice = v ?? 0),
                ),
              if (!_choices.any((row) => row['kind'] == _kind))
                const Text(
                  'Создайте и опубликуйте титул или достижение в каталоге.',
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _reason,
                maxLength: 240,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Причина (для истории владельца)',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: !_choices.any((row) => row['kind'] == _kind)
                    ? null
                    : () => _manage('grant'),
                icon: const Icon(Icons.card_giftcard),
                label: Text(
                  _busy
                      ? 'Сохранение…'
                      : _all
                      ? 'Выдать всем'
                      : 'Выдать пользователю',
                ),
              ),
              if (_all && _choices.any((row) => row['kind'] == _kind))
                TextButton(
                  onPressed: () => _manage('revoke'),
                  child: const Text('Отозвать выбранную награду у всех'),
                ),
              if (!_all) ...[
                const SizedBox(height: 24),
                Text(
                  'Награды: $_recipientName',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                for (final a in _awards)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Text(
                      a['icon'],
                      style: const TextStyle(fontSize: 26),
                    ),
                    title: Text(a['label']),
                    subtitle: Text(
                      a['kind'] == 'title' ? 'Титул' : 'Выдано владельцем',
                    ),
                    trailing: IconButton(
                      tooltip: 'Отозвать',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => _manage('revoke', award: a),
                    ),
                  ),
              ],
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                TextButton(
                  onPressed: _load,
                  child: const Text('Повторить загрузку'),
                ),
              ],
            ],
          ),
        );
}
