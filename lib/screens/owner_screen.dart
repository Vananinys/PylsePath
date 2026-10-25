import 'package:flutter/material.dart';

import '../widgets/owner_award_management.dart';
import 'developer_panel.dart';
import 'moderation_screen.dart';

import '../models/owner_award.dart';
import '../services/achievements_service.dart';
import '../services/owner_service.dart';

class OwnerScreen extends StatefulWidget {
  const OwnerScreen({super.key});
  @override
  State<OwnerScreen> createState() => _OwnerScreenState();
}

class _OwnerScreenState extends State<OwnerScreen>
    with SingleTickerProviderStateMixin {
  final _service = OwnerService();
  late final TabController _tabs;
  bool _loading = true, _owner = false;
  String? _error;
  List<CatalogAchievement> _items = [];
  List<Map<String, dynamic>> _titles = [];
  List<OwnerAward> _awards = [];
  int _tab = 0;
  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 6, vsync: this)
      ..addListener(() {
        if (mounted && !_tabs.indexIsChanging)
          setState(() => _tab = _tabs.index);
      });
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rights = await _service.entitlements();
      final owner = rights['is_owner'] == true;
      final items = owner
          ? await _service.catalog(includeInactive: true)
          : <CatalogAchievement>[];
      AchievementsService.catalog = List.unmodifiable(
        items.where((item) => item.row['active'] == true),
      );
      final titles = owner
          ? await _service.titles(includeInactive: true)
          : <Map<String, dynamic>>[];
      final awards = owner ? await _service.awards() : <OwnerAward>[];
      AchievementsService.ownerIssued = awards;
      if (mounted) {
        setState(() {
          _owner = owner;
          _items = items;
          _titles = titles;
          _awards = awards;
          _loading = false;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Не удалось проверить права. Проверьте интернет.';
        });
      }
    }
  }

  Future<void> _editTitle([Map<String, dynamic>? row]) async {
    final title = TextEditingController(text: row?['title'] as String? ?? '');
    final description = TextEditingController(
      text: row?['description'] as String? ?? '',
    );
    final icon = TextEditingController(text: row?['icon'] as String? ?? '🏅');
    var active = row?['active'] as bool? ?? true;
    final form = GlobalKey<FormState>();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(row == null ? 'Новый титул' : 'Изменить титул'),
          content: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: title,
                  maxLength: 48,
                  decoration: const InputDecoration(labelText: 'Название'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Введите название' : null,
                ),
                TextFormField(
                  controller: description,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: 'Описание'),
                ),
                TextFormField(
                  controller: icon,
                  maxLength: 16,
                  decoration: const InputDecoration(labelText: 'Значок'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Опубликован'),
                  value: active,
                  onChanged: (v) => update(() => active = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () async {
                if (!form.currentState!.validate()) return;
                try {
                  await _service.saveTitle({
                    if (row != null) 'id': row['id'],
                    'title': title.text.trim(),
                    'description': description.text.trim(),
                    'icon': icon.text.trim(),
                    'active': active,
                  });
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } catch (_) {
                  if (mounted)
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Не удалось сохранить титул. Проверьте интернет.',
                        ),
                      ),
                    );
                }
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    title.dispose();
    description.dispose();
    icon.dispose();
    await _load();
  }

  Future<void> _grant() async {
    final catalogNames = _items
        .map((item) => item.row['title'] as String)
        .toSet();
    final choices = <({String kind, String key, String label, String icon})>[
      ..._titles
          .where((t) => t['active'] == true)
          .map(
            (t) => (
              kind: 'title',
              key: t['id'] as String,
              label: t['title'] as String,
              icon: t['icon'] as String,
            ),
          ),
      ..._items
          .where((a) => a.row['active'] == true)
          .map(
            (a) => (
              kind: 'achievement',
              key: 'catalog:${a.row['id']}',
              label: a.row['title'] as String,
              icon: a.row['icon'] as String,
            ),
          ),
      ...AchievementsService.badges(const [])
          .where((badge) => !catalogNames.contains(badge.title))
          .map(
            (badge) => (
              kind: 'achievement',
              key: 'builtin:${badge.title}',
              label: badge.title,
              icon: badge.icon,
            ),
          ),
    ];
    if (choices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Сначала создайте и опубликуйте титул или достижение.'),
        ),
      );
      return;
    }
    var selected = 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Выдать себе награду'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Награда появится в вашем профиле. Выданное достижение будет отмечено как награда владельца.',
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: selected,
                isExpanded: true,
                items: [
                  for (var i = 0; i < choices.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        '${choices[i].icon} ${choices[i].label}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => update(() => selected = v ?? 0),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Выдать себе'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      final choice = choices[selected];
      if (choice.kind == 'title') {
        await _service.grantTitle(choice.key);
      } else {
        await _service.grant(
          kind: choice.kind,
          key: choice.key,
          label: choice.label,
          icon: choice.icon,
        );
      }
      await _load();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Выдано: ${choice.icon} ${choice.label}')),
        );
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось выдать награду. Проверьте подключение и публикацию.',
            ),
          ),
        );
    }
  }

  Future<void> _revoke(OwnerAward award) async {
    try {
      await _service.revoke(award.id);
      await _load();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось снять награду.')),
        );
    }
  }

  Widget _catalogBody() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Card(
        child: ListTile(
          leading: Icon(Icons.verified_user),
          title: Text('Права владельца активны'),
          subtitle: Text(
            'Только владелец управляет каталогом и выдаёт награды пользователям.',
          ),
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.group_add_outlined),
          title: const Text('Выдать пользователю или всем'),
          subtitle: const Text(
            'Поиск получателя, массовая выдача и история действий',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _tabs.animateTo(3),
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.card_giftcard),
          title: const Text('Выдать себе награду'),
          subtitle: const Text(
            'Титул появится в профиле, достижение — в списке достижений.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _grant,
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: ListTile(
          leading: const Icon(Icons.developer_mode),
          title: const Text('Панель разработчика'),
          subtitle: const Text('Проверки GPS, шагов, кэша и тестовые сценарии'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _tabs.animateTo(4),
        ),
      ),
      Text(
        _tab == 0 ? 'Достижения приложения' : 'Каталог титулов',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
      Text(
        _tab == 0
            ? 'Выберите автоматическое условие по тренировкам или ручную выдачу за событие. Опубликованные награды доступны во вкладке «Выдача».'
            : 'Выдавайте титулы людям или всем пользователям. Каждый выбирает свой титул в оформлении профиля.',
      ),
      if (_tab == 0) ...[
        for (final item in _items)
          Card(
            child: ListTile(
              leading: Text(
                item.row['icon'],
                style: const TextStyle(fontSize: 28),
              ),
              title: Text(item.row['title']),
              subtitle: Text(
                '${CatalogAchievement.metrics[item.row['metric']]}${item.row['metric'] == 'manual' ? '' : ': ${item.row['threshold']}'} · ${item.row['active'] == true ? 'Опубликовано' : 'Скрыто'}',
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => _edit(item),
            ),
          ),
      ] else ...[
        for (final title in _titles)
          Card(
            child: ListTile(
              leading: Text(
                title['icon'],
                style: const TextStyle(fontSize: 28),
              ),
              title: Text(title['title']),
              subtitle: Text(
                '${title['description'] ?? ''}${title['active'] == true ? ' · Опубликован' : ' · Скрыт'}',
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => _editTitle(title),
            ),
          ),
      ],
      if ((_tab == 0 && _items.isEmpty) || (_tab == 1 && _titles.isEmpty))
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text('Пока пусто. Нажмите +, чтобы добавить первую запись.'),
        ),
      const SizedBox(height: 90),
    ],
  );

  Widget _awardsBody() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'Награды моего аккаунта',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
      const Text(
        'Титул показывается в профиле. Выданные вручную достижения помечены как награда владельца.',
      ),
      if (_awards.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Наград пока нет. Откройте вкладку каталога и нажмите «Выдать себе награду».',
          ),
        ),
      for (final award in _awards)
        Card(
          child: ListTile(
            leading: Text(award.icon, style: const TextStyle(fontSize: 28)),
            title: Text(award.label),
            subtitle: Text(
              '${award.kind == 'title' ? (award.equipped ? 'Титул надет' : 'Титул') : 'Достижение владельца'}${award.grantedAt == null ? '' : ' · ${award.grantedAt!.toLocal().toString().substring(0, 10)}'}',
            ),
            trailing: IconButton(
              tooltip: 'Снять награду',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _revoke(award),
            ),
          ),
        ),
    ],
  );

  Future<void> _edit([CatalogAchievement? item]) async {
    final row = item?.row;
    final title = TextEditingController(text: row?['title'] as String?);
    final description = TextEditingController(
      text: row?['description'] as String?,
    );
    final icon = TextEditingController(text: row?['icon'] as String? ?? '🏆');
    final threshold = TextEditingController(
      text: row?['threshold']?.toString() ?? '10',
    );
    var metric = row?['metric'] as String? ?? 'total_km';
    var active = row?['active'] as bool? ?? true;
    var busy = false;
    String? error;
    final form = GlobalKey<FormState>();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(row == null ? 'Новое достижение' : 'Изменить достижение'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: title,
                      maxLength: 60,
                      decoration: const InputDecoration(labelText: 'Название'),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'Введите название'
                          : null,
                    ),
                    TextFormField(
                      controller: description,
                      maxLength: 240,
                      maxLines: 3,
                      decoration: const InputDecoration(labelText: 'Описание'),
                    ),
                    TextFormField(
                      controller: icon,
                      maxLength: 16,
                      decoration: const InputDecoration(labelText: 'Эмодзи'),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'Введите эмодзи'
                          : null,
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: metric,
                      isExpanded: true,
                      items: CatalogAchievement.metrics.entries
                          .map(
                            (e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                          )
                          .toList(),
                      onChanged: busy ? null : (v) => update(() => metric = v!),
                    ),
                    if (metric != 'manual')
                      TextFormField(
                        controller: threshold,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Порог достижения',
                        ),
                        validator: (v) {
                          final n = double.tryParse(
                            (v ?? '').replaceAll(',', '.'),
                          );
                          return n == null || !n.isFinite || n <= 0 || n > 1e9
                              ? 'Укажите число от 0 до 1 млрд'
                              : null;
                        },
                      ),
                    if (metric == 'manual')
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'Это награда за событие или участие. После публикации выдайте её человеку или всем во вкладке «Выдача».',
                        ),
                      ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Опубликовано'),
                      value: active,
                      onChanged: busy ? null : (v) => update(() => active = v),
                    ),
                    if (error != null)
                      Text(error!, style: const TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(dialogContext),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (!form.currentState!.validate()) return;
                      update(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await _service.save({
                          if (row != null) 'id': row['id'],
                          'title': title.text.trim(),
                          'description': description.text.trim(),
                          'icon': icon.text.trim(),
                          'metric': metric,
                          'threshold': metric == 'manual'
                              ? 1
                              : double.parse(
                                  threshold.text.replaceAll(',', '.'),
                                ),
                          'active': active,
                        });
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } catch (_) {
                        update(() {
                          busy = false;
                          error = 'Не удалось сохранить. Нужны права владельца и интернет.';
                        });
                      }
                    },
              child: Text(busy ? 'Сохранение…' : 'Сохранить'),
            ),
          ],
        ),
      ),
    );
    title.dispose();
    description.dispose();
    icon.dispose();
    threshold.dispose();
    await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Владелец приложения'),
      bottom: _owner && !_loading
          ? TabBar(
              controller: _tabs,
              isScrollable: true,
              tabs: const [
                Tab(text: 'Достижения'),
                Tab(text: 'Титулы'),
                Tab(text: 'Мои награды'),
                Tab(text: 'Выдача'),
                Tab(text: 'Разработчик'),
                Tab(text: 'Модерация'),
              ],
            )
          : null,
    ),
    floatingActionButton: _owner && _tab < 3
        ? FloatingActionButton(
            onPressed: () => _tab == 0
                ? _edit()
                : _tab == 1
                ? _editTitle()
                : _grant(),
            child: Icon(_tab == 2 ? Icons.card_giftcard : Icons.add),
          )
        : null,
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(
            child: TextButton(onPressed: _load, child: Text(_error!)),
          )
        : !_owner
        ? const Center(
            child: Text('Управление доступно только владельцу приложения.'),
          )
        : TabBarView(
            controller: _tabs,
            children: [
              _catalogBody(),
              _catalogBody(),
              _awardsBody(),
              const OwnerAwardManagement(),
              const DeveloperPanel(),
              const ModerationScreen(),
            ],
          ),
  );
}
