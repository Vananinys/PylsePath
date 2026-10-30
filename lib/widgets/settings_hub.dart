import 'package:flutter/material.dart';

import '../ui/app_theme.dart';

class SettingsSectionHeading extends StatelessWidget {
  const SettingsSectionHeading(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}

class SettingsHub extends StatefulWidget {
  const SettingsHub({
    super.key,
    required this.children,
    required this.summaries,
    this.onDeveloper,
  });
  final List<Widget> children;
  final Map<String, String> summaries;
  final VoidCallback? onDeveloper;
  @override
  State<SettingsHub> createState() => _SettingsHubState();
}

class _SettingsHubState extends State<SettingsHub> {
  String? _selected;
  String _query = '';
  int _secretTaps = 0;
  bool _developer = false;
  static const _icons = {
    'Внешний вид': Icons.palette_outlined,
    'Шагомер и активность': Icons.directions_walk,
    'Уведомления': Icons.notifications_outlined,
    'Тренировки': Icons.route_outlined,
    'Приватность': Icons.shield_outlined,
    'Аккаунт и данные': Icons.cloud_done_outlined,
  };
  String _group(String title) => switch (title) {
    'Запись тренировки и помощники' ||
    'Экспериментальные функции' => 'Тренировки',
    'Приложение' => 'Аккаунт и данные',
    _ => title,
  };
  @override
  Widget build(BuildContext context) {
    final groups = <String, List<Widget>>{};
    String? current;
    for (final child in widget.children) {
      if (child is SettingsSectionHeading) {
        current = _group(child.title);
        groups.putIfAbsent(current, () => []);
        continue;
      }
      if (child is! Divider && current != null) groups[current]!.add(child);
    }
    final selected = _selected;
    return PopScope(
      canPop: selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _selected = null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            onTap: widget.onDeveloper == null
                ? null
                : () {
                    if (++_secretTaps >= 7) setState(() => _developer = true);
                  },
            child: Text(selected ?? 'Настройки'),
          ),
          leading: BackButton(
            onPressed: () {
              if (selected == null) {
                Navigator.pop(context);
              } else {
                setState(() => _selected = null);
              }
            },
          ),
        ),
        body: AnimatedSwitcher(
          duration: AppMotion.brief(context),
          child: selected == null
              ? ListView(
                  key: const ValueKey('hub'),
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(
                      'Настройте под себя',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Выберите задачу — внутри будут только связанные с ней параметры.',
                    ),
                    const SizedBox(height: 20),
                    if (_developer && widget.onDeveloper != null)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.science_outlined),
                          title: const Text('Для разработчика'),
                          subtitle: const Text(
                            'Домашние сценарии и управление',
                          ),
                          onTap: widget.onDeveloper,
                        ),
                      ),
                    TextField(
                      onChanged: (v) =>
                          setState(() => _query = v.toLowerCase().trim()),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Найти раздел',
                      ),
                    ),
                    const SizedBox(height: 20),
                    LayoutBuilder(
                      builder: (c, constraints) {
                        final columns =
                            constraints.maxWidth >= 340 &&
                                MediaQuery.textScalerOf(c).scale(1) < 1.3
                            ? 2
                            : 1;
                        final matches = groups.keys
                            .where(
                              (name) => '$name ${widget.summaries[name]}'
                                  .toLowerCase()
                                  .contains(_query),
                            )
                            .toList();
                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final name in matches)
                              SizedBox(
                                width:
                                    (constraints.maxWidth -
                                        (columns - 1) * 12) /
                                    columns,
                                child: Card(
                                  elevation: 0,
                                  color: Theme.of(c)
                                      .colorScheme
                                      .surfaceContainerLow,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24),
                                    side: BorderSide(
                                      color: Theme.of(c)
                                          .colorScheme
                                          .outlineVariant
                                          .withValues(alpha: .45),
                                    ),
                                  ),
                                  margin: EdgeInsets.zero,
                                  child: InkWell(
                                    onTap: () =>
                                        setState(() => _selected = name),
                                    borderRadius: BorderRadius.circular(22),
                                    child: Padding(
                                      padding: const EdgeInsets.all(18),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          DecoratedBox(
                                            decoration: BoxDecoration(
                                              color: Theme.of(c)
                                                  .colorScheme
                                                  .primaryContainer,
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.all(10),
                                              child: Icon(
                                                _icons[name] ??
                                                    Icons.settings_outlined,
                                                color: Theme.of(c)
                                                    .colorScheme
                                                    .primary,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 16),
                                          Text(
                                            name,
                                            style: Theme.of(c)
                                                .textTheme
                                                .titleMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            widget.summaries[name] ?? '',
                                            style: Theme.of(c)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (matches.isEmpty)
                              const Text(
                                'Раздел не найден. Попробуйте «уведомления», «тренировки» или «приватность».',
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                )
              : ListView(
                  key: ValueKey(selected),
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        widget.summaries[selected] ?? '',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                    ...groups[selected] ?? [],
                  ],
                ),
        ),
      ),
    );
  }
}
