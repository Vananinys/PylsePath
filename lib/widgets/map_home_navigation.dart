import 'package:flutter/material.dart';

import 'widget_size_observer.dart';

class MapHomeNavigation extends StatelessWidget {
  const MapHomeNavigation({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });
  final int selectedIndex;
  final ValueChanged<int>? onSelected;

  @override
  Widget build(BuildContext context) => MediaQuery.removePadding(
    context: context,
    removeTop: true,
    child: NavigationBar(
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelected,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.map_outlined),
          selectedIcon: Icon(Icons.map),
          label: 'Карта',
        ),
        NavigationDestination(
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore),
          label: 'Сообщество',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: 'Профиль',
        ),
        NavigationDestination(icon: Icon(Icons.menu), label: 'Меню'),
      ],
    ),
  );
}

/// The primary map stays mounted beneath these sections, including its workout.
class MapHomeSections extends StatefulWidget {
  const MapHomeSections({
    super.key,
    required this.initialIndex,
    required this.community,
    required this.profile,
    required this.onMenu,
  });
  final int initialIndex;
  final Widget community;
  final Widget profile;
  final VoidCallback onMenu;
  @override
  State<MapHomeSections> createState() => _MapHomeSectionsState();
}

class _MapHomeSectionsState extends State<MapHomeSections> {
  late int _index = widget.initialIndex;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _index - 1,
      children: [widget.community, widget.profile],
    ),
    bottomNavigationBar: MapHomeNavigation(
      selectedIndex: _index,
      onSelected: (index) {
        if (index == 0 || index == 3) {
          Navigator.pop(context);
          if (index == 3) widget.onMenu();
        } else {
          setState(() => _index = index);
        }
      },
    ),
  );
}

/// Buttons and tabs share one layout, including the bottom system inset.
class MapHomeDock extends StatelessWidget {
  const MapHomeDock({
    super.key,
    required this.actions,
    required this.navigation,
    required this.onSize,
  });
  final Widget actions;
  final Widget navigation;
  final ValueChanged<Size> onSize;
  @override
  Widget build(BuildContext context) => WidgetSizeObserver(
    onSize: onSize,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: actions,
        ),
        navigation,
      ],
    ),
  );
}
