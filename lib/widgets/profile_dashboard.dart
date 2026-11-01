import 'package:flutter/material.dart';

/// Presentation only: all data, persistence and actions stay in ProfileScreen.
class ProfileDashboard extends StatelessWidget {
  const ProfileDashboard({
    super.key,
    required this.identity,
    required this.stats,
    required this.awards,
    required this.progress,
    required this.activity,
    required this.garage,
    required this.details,
    required this.privacy,
    required this.onHistory,
    required this.onTraining,
    required this.onEdit,
    required this.onRefresh,
    required this.onCustomize,
    this.notices = const [],
  });
  final Widget identity,
      stats,
      awards,
      progress,
      activity,
      garage,
      details,
      privacy;
  final List<Widget> notices;
  final VoidCallback onHistory, onTraining, onEdit;
  final VoidCallback? onCustomize;
  final Future<void> Function() onRefresh;

  Widget _page(String key, List<Widget> children) => Builder(
    builder: (context) => CustomScrollView(
      key: PageStorageKey('profile-$key'),
      slivers: [
        SliverOverlapInjector(
          handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          sliver: SliverList.list(
            children: children
                .expand((child) => [child, const SizedBox(height: 20)])
                .toList(),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tabHeight = MediaQuery.textScalerOf(context).scale(14) + 32;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Мой профиль'),
          actions: [
            IconButton(
              onPressed: onRefresh,
              tooltip: 'Обновить профиль',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: onRefresh,
          child: NestedScrollView(
            headerSliverBuilder: (context, scrolled) => [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      identity,
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: onEdit,
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Личные данные'),
                          ),
                          OutlinedButton.icon(
                            onPressed: onCustomize,
                            icon: const Icon(Icons.palette_outlined),
                            label: const Text('Оформление'),
                          ),
                        ],
                      ),
                      ...notices,
                    ],
                  ),
                ),
              ),
              SliverOverlapAbsorber(
                handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                  context,
                ),
                sliver: SliverPersistentHeader(
                  pinned: true,
                  delegate: _ProfileTabs(
                    height: tabHeight,
                    color: colors.surface,
                    child: const TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: [
                        Tab(text: 'Обзор'),
                        Tab(text: 'Прогресс'),
                        Tab(text: 'Гараж'),
                        Tab(text: 'Обо мне'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            body: TabBarView(
              children: [
                _page('overview', [
                  stats,
                  _action(
                    context,
                    Icons.history_rounded,
                    'История тренировок',
                    'Треки, результаты и сохранённые записи',
                    onHistory,
                  ),
                  awards,
                  _action(
                    context,
                    Icons.calendar_month_outlined,
                    'Тренировочный центр',
                    'Календарь, ритм недели и личные ориентиры',
                    onTraining,
                  ),
                ]),
                _page('progress', [
                  progress,
                  activity,
                  _action(
                    context,
                    Icons.insights_outlined,
                    'Посмотреть календарь',
                    'Разобраться в своём ритме тренировок',
                    onTraining,
                  ),
                ]),
                _page('garage', [garage]),
                _page('about', [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          details,
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: onEdit,
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Изменить личные данные'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Видимость активности',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          privacy,
                        ],
                      ),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _action(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
}

class _ProfileTabs extends SliverPersistentHeaderDelegate {
  _ProfileTabs({
    required this.height,
    required this.color,
    required this.child,
  });
  final double height;
  final Color color;
  final Widget child;
  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Material(
    color: color,
    elevation: overlapsContent ? 2 : 0,
    child: SizedBox.expand(child: child),
  );
  @override
  bool shouldRebuild(covariant _ProfileTabs oldDelegate) =>
      oldDelegate.height != height || oldDelegate.color != color;
}

class ProfileSummaryGrid extends StatelessWidget {
  const ProfileSummaryGrid({
    super.key,
    required this.distance,
    required this.workouts,
    required this.duration,
    required this.elevation,
  });
  final String distance, workouts, duration, elevation;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Ваши итоги', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(
        'По сохранённым тренировкам за всё время',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, constraints) {
          final single =
              constraints.maxWidth < 340 &&
              MediaQuery.textScalerOf(context).scale(14) > 20;
          final width = single
              ? constraints.maxWidth
              : (constraints.maxWidth - 10) / 2;
          final values = [
            (Icons.route_outlined, distance, 'Дистанция'),
            (Icons.fitness_center_outlined, workouts, 'Тренировки'),
            (Icons.schedule_outlined, duration, 'Время в движении'),
            (Icons.landscape_outlined, elevation, 'Набор высоты'),
          ];
          final colors = Theme.of(context).colorScheme;
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final (icon, value, label) in values)
                SizedBox(
                  width: width,
                  child: Card(
                    margin: EdgeInsets.zero,
                    color: colors.surfaceContainerLow,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(icon, color: colors.primary, size: 22),
                          const SizedBox(height: 12),
                          Text(
                            value,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            label,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ],
  );
}
