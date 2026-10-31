import 'package:flutter/material.dart';

/// Keeps the existing navigation callbacks and module visibility intact.
class NavigationMenu extends StatefulWidget {
  const NavigationMenu({super.key, required this.children});
  final List<Widget> children;
  @override
  State<NavigationMenu> createState() => _NavigationMenuState();
}

class _NavigationMenuState extends State<NavigationMenu> {
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _text(Widget? widget) => widget is Text ? widget.data ?? '' : '';
  String _section(String name) => switch (name) {
    'Сохранённые маршруты' ||
    'Сохраненные маршруты' ||
    'Мои места' ||
    'Офлайн-карты' => 'Маршруты и места',
    'Тренировочный центр' ||
    'Достижения' ||
    'Тепловая карта' ||
    'Активность за день' ||
    'Мой гараж' => 'Моя активность',
    'Сообщения' ||
    'Сообщество' ||
    'Клубы' ||
    'Совместная поездка' ||
    'События и челленджи' ||
    'Уведомления' => 'Вместе',
    _ => 'Профиль и приложение',
  };

  @override
  Widget build(BuildContext context) {
    final query = _search.text.toLowerCase().trim();
    final groups = <String, List<Widget>>{};
    for (final child in widget.children) {
      if (child is Divider) continue;
      final title = child is ListTile ? _text(child.title) : '';
      final subtitle = child is ListTile ? _text(child.subtitle) : '';
      if (query.isNotEmpty && !'$title $subtitle'.toLowerCase().contains(query))
        continue;
      groups.putIfAbsent(_section(title), () => []).add(child);
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: 'Найти раздел',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Очистить поиск',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(_search.clear),
                    ),
            ),
          ),
        ),
        for (final group in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
            child: Text(
              group.key,
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          ...group.value,
        ],
        if (groups.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Раздел не найден. Попробуйте другое название. Дополнительные разделы включаются в настройках внешнего вида.',
            ),
          ),
      ],
    );
  }
}
