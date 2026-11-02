import 'package:flutter/material.dart';

class MapHomeNavigation extends StatelessWidget {
  const MapHomeNavigation({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });
  final int selectedIndex;
  final ValueChanged<int>? onSelected;

  @override
  Widget build(BuildContext context) => NavigationBar(
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
