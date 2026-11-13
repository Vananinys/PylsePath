import 'package:flutter/material.dart';

/// Public sections only; the screen retains authorization and real actions.
class PublicProfileDashboard extends StatelessWidget {
  const PublicProfileDashboard({
    super.key,
    required this.identity,
    required this.actions,
    required this.awards,
    required this.activity,
    required this.details,
    required this.garage,
    required this.posts,
    required this.onRefresh,
  });
  final Widget identity, actions, awards, activity, details, garage, posts;
  final Future<void> Function() onRefresh;

  Widget _page(String name, List<Widget> children) => Builder(
    builder: (context) => CustomScrollView(
      key: PageStorageKey('public-profile-$name'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverOverlapInjector(
          handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          sliver: SliverList.list(
            children: [
              for (final child in children) ...[
                child,
                const SizedBox(height: 20),
              ],
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: Scaffold(
      appBar: AppBar(title: const Text('Профиль участника')),
      body: RefreshIndicator(
        onRefresh: onRefresh,
        notificationPredicate: (notification) => notification.depth <= 2,
        child: NestedScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          headerSliverBuilder: (context, scrolled) => [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [identity, const SizedBox(height: 16), actions],
                ),
              ),
            ),
            SliverOverlapAbsorber(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
              sliver: SliverPersistentHeader(
                pinned: true,
                delegate: _PublicTabs(
                  height: MediaQuery.textScalerOf(context).scale(14) + 32,
                  color: Theme.of(context).colorScheme.surface,
                ),
              ),
            ),
          ],
          body: TabBarView(
            children: [
              _page('overview', [
                Text(
                  'Об участнике',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                details,
                awards,
              ]),
              _page('activity', [activity]),
              _page('garage', [
                Text('Гараж', style: Theme.of(context).textTheme.titleLarge),
                garage,
              ]),
              _page('posts', [
                Text(
                  'Публикации',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                posts,
              ]),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PublicTabs extends SliverPersistentHeaderDelegate {
  _PublicTabs({required this.height, required this.color});
  final double height;
  final Color color;
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
    child: const SizedBox.expand(
      child: TabBar(
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        tabs: [
          Tab(text: 'Обзор'),
          Tab(text: 'Активность'),
          Tab(text: 'Гараж'),
          Tab(text: 'Публикации'),
        ],
      ),
    ),
  );
  @override
  bool shouldRebuild(covariant _PublicTabs oldDelegate) =>
      height != oldDelegate.height || color != oldDelegate.color;
}
