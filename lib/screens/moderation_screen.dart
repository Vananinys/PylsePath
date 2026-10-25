import 'dart:async';

import 'package:flutter/material.dart';

import '../data/user_scope.dart';
import '../services/moderation_service.dart';
import '../widgets/moderation_dialogs.dart';

class ModerationScreen extends StatefulWidget {
  const ModerationScreen({super.key});
  @override
  State<ModerationScreen> createState() => _ModerationScreenState();
}

class _ModerationScreenState extends State<ModerationScreen> {
  final _service = ModerationService(), _search = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  String _kind = 'users';
  String? _error;
  bool _loading = true, _allowed = false, _more = false;
  int _generation = 0;
  Timer? _debounce;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool append = false}) async {
    final generation = ++_generation, owner = UserScope.currentUserId();
    final kind = _kind;
    setState(() {
      _loading = true;
      _error = null;
      if (!append) _rows = [];
    });
    try {
      final rights = await _service.status();
      if (!mounted ||
          generation != _generation ||
          owner != UserScope.currentUserId())
        return;
      if (!rights.isModerator) {
        setState(() {
          _allowed = false;
          _loading = false;
        });
        return;
      }
      final rows = await _service.list(
        kind,
        query: _search.text.trim(),
        offset: append ? _rows.length : 0,
      );
      if (!mounted ||
          generation != _generation ||
          owner != UserScope.currentUserId())
        return;
      setState(() {
        _allowed = true;
        _rows = append ? [..._rows, ...rows] : rows;
        _more = rows.length == 30;
        _loading = false;
      });
    } catch (e) {
      if (mounted && generation == _generation)
        setState(() {
          _loading = false;
          _error = e is ModerationException
              ? e.message
              : 'Не удалось загрузить данные модерации. Проверьте интернет.';
        });
    }
  }

  String _time(Object? value) => value == null
      ? 'бессрочно'
      : DateTime.tryParse(value.toString())
                ?.toLocal()
                .toString()
                .substring(0, 16) ??
            '—';
  Future<void> _act(Map<String, dynamic> row) async {
    final result = await showModerationAction(
      context,
      userId: row['id'] as String?,
      userName: row['username'] as String?,
      contentId: _kind == 'hidden' ? row['id'] as String : null,
      kind: row['kind'] as String? ?? 'post',
      restore: _kind == 'hidden',
      unban: row['is_banned'] == true,
    );
    if (result && mounted) await _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Модерация сообщества'),
      actions: [
        IconButton(
          tooltip: 'Обновить',
          onPressed: _loading ? null : () => _load(),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              for (final entry in {
                'users': 'Пользователи',
                'bans': 'Баны',
                'hidden': 'Удалённые записи',
                'audit': 'Журнал',
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(entry.value),
                    selected: _kind == entry.key,
                    onSelected: (_) {
                      setState(() => _kind = entry.key);
                      _load();
                    },
                  ),
                ),
            ],
          ),
        ),
        if (_kind == 'users' || _kind == 'bans')
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _search,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Поиск по имени',
                prefixIcon: Icon(Icons.search),
                counterText: '',
              ),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(
                  const Duration(milliseconds: 350),
                  () => _load(),
                );
              },
            ),
          ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextButton(onPressed: () => _load(), child: Text(_error!)),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(),
            child: ListView(
              padding: const EdgeInsets.all(12),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (!_loading && _error == null && !_allowed)
                  const ListTile(
                    title: Text('Доступ только модераторам сообщества.'),
                  ),
                if (_allowed && _rows.isEmpty && !_loading)
                  const ListTile(title: Text('Записей пока нет.')),
                for (final row in _rows)
                  Card(
                    child: _kind == 'audit'
                        ? ListTile(
                            leading: const Icon(Icons.history),
                            title: Text(
                              '${switch (row['action']) {
                                'ban' => 'Бан',
                                'unban' => 'Снятие бана',
                                'hide' => 'Удаление',
                                _ => 'Восстановление',
                              }} · ${row['target_name'] ?? 'Пользователь'}',
                            ),
                            subtitle: Text(
                              '${row['actor_name'] ?? 'Модератор'} · ${_time(row['created_at'])}\n${row['reason']}',
                            ),
                          )
                        : _kind == 'hidden'
                        ? ListTile(
                            leading: Icon(
                              row['kind'] == 'comment'
                                  ? Icons.comment_outlined
                                  : Icons.article_outlined,
                            ),
                            title: Text(
                              '${row['username']} · ${row['kind'] == 'comment' ? 'Комментарий' : 'Публикация'}',
                            ),
                            subtitle: Text(
                              row['body']?.toString().isNotEmpty == true
                                  ? row['body'] as String
                                  : 'Запись с вложением',
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              tooltip: 'Восстановить',
                              icon: const Icon(Icons.restore),
                              onPressed: () => _act(row),
                            ),
                          )
                        : ListTile(
                            leading: Icon(
                              row['is_moderator'] == true
                                  ? Icons.verified_user
                                  : row['is_banned'] == true
                                  ? Icons.block
                                  : Icons.person_outline,
                            ),
                            title: Text(
                              row['username'] as String? ?? 'Без имени',
                            ),
                            subtitle: Text(
                              row['is_moderator'] == true
                                  ? 'Модератор · защищённый аккаунт'
                                  : row['is_banned'] == true
                                  ? 'Бан ${_time(row['expires_at'])}\n${row['reason']}'
                                  : 'Публикации разрешены',
                            ),
                            trailing:
                                row['is_moderator'] == true ||
                                    row['id'] == UserScope.currentUserId()
                                ? null
                                : TextButton(
                                    onPressed: () => _act(row),
                                    child: Text(
                                      row['is_banned'] == true
                                          ? 'Снять бан'
                                          : 'Бан',
                                    ),
                                  ),
                          ),
                  ),
                if (_more)
                  OutlinedButton(
                    onPressed: _loading ? null : () => _load(append: true),
                    child: const Text('Показать ещё'),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
