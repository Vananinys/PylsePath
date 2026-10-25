import 'package:flutter/material.dart';

import '../data/ui_modules.dart';

/// Interface choices only: background services retain their own explicit settings.
class ModuleSettingsPanel extends StatefulWidget {
  const ModuleSettingsPanel({
    super.key,
    required this.enabled,
    required this.preset,
    required this.onPreset,
    required this.onChanged,
  });
  final Set<String> enabled;
  final UiPreset preset;
  final VoidCallback onPreset;
  final Future<void> Function(String id, bool value) onChanged;
  @override
  State<ModuleSettingsPanel> createState() => _ModuleSettingsPanelState();
}

class _ModuleSettingsPanelState extends State<ModuleSettingsPanel> {
  String _query = '';
  bool _saving = false;
  Future<void> _change(String id, bool value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onChanged(id, value);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось сохранить выбор. Попробуйте ещё раз.'),
          ),
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _matches(UiModule module) {
    final text = '${module.title} ${UiModules.descriptions[module.id]}'
        .toLowerCase();
    return text.contains(_query.toLowerCase().trim());
  }

  @override
  Widget build(BuildContext context) {
    final custom =
        widget.enabled.length != widget.preset.modules.length ||
        !widget.enabled.containsAll(widget.preset.modules);
    final groups = {
      for (final group in UiModules.groups.entries)
        group.key: UiModules.optionalModules
            .where(
              (module) => group.value.contains(module.id) && _matches(module),
            )
            .toList(),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(
            'Соберите своё приложение',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Выберите разделы, которые нужны вам в меню. Выключение скрывает раздел, но сохраняет историю, награды и настройки.',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.dashboard_customize_outlined),
          title: Text(
            custom
                ? 'Свой набор · ${widget.enabled.intersection(UiModules.allIds).length} из ${UiModules.allIds.length}'
                : '${widget.preset.emoji} ${widget.preset.title}',
          ),
          subtitle: const Text(
            'Готовые наборы — быстрый старт. После выбора можно менять каждый переключатель.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _saving ? null : widget.onPreset,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextField(
            decoration: const InputDecoration(
              labelText: 'Найти функцию',
              hintText: 'Например: шаги, GPX, друзья',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        if (groups.values.every((modules) => modules.isEmpty))
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Раздел не найден. Настройки шагомера, записи и уведомлений находятся ниже.',
            ),
          ),
        for (final group in groups.entries)
          if (group.value.isNotEmpty)
            Card(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                    child: Text(
                      '${group.key} · ${group.value.where((module) => widget.enabled.contains(module.id)).length} из ${group.value.length}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  for (final module in group.value)
                    SwitchListTile(
                      secondary: Icon(module.icon),
                      title: Text(module.title),
                      subtitle: Text(
                        '${UiModules.descriptions[module.id]}\n${widget.enabled.contains(module.id) ? "Показан в приложении" : "Скрыт в приложении"}',
                      ),
                      value: widget.enabled.contains(module.id),
                      onChanged: _saving
                          ? null
                          : (value) => _change(module.id, value),
                    ),
                ],
              ),
            ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Text(
            'Всегда доступны: карта, запись тренировок, профиль и резервная копия. Ниже отдельно настраиваются шагомер, помощники, системные уведомления и приватность. Скрытие чата или сообщества не отключает уведомления и передачу геопозиции.',
            style: TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }
}
