import 'package:flutter/material.dart';

import '../data/navigation_preferences.dart';

class NavigationPreferencesScreen extends StatelessWidget {
  const NavigationPreferencesScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final prefs = NavigationPreferences.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Карта и навигация')),
      body: ListenableBuilder(
        listenable: prefs,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Цвет маршрута',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              children: [
                for (var i = 0; i < NavigationPreferences.palette.length; i++)
                  Semantics(
                    label: ['Оранжевый', 'Синий', 'Фиолетовый', 'Бирюзовый'][i],
                    selected: prefs.colorIndex == i,
                    child: InkWell(
                      onTap: () => prefs.update(color: i),
                      customBorder: const CircleBorder(),
                      child: CircleAvatar(
                        backgroundColor: NavigationPreferences.palette[i],
                        radius: 24,
                        child: prefs.colorIndex == i
                            ? const Icon(Icons.check, color: Colors.white)
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            Text('Толщина линии · ${prefs.lineWidth.toStringAsFixed(1)}'),
            Slider(
              value: prefs.lineWidth,
              min: 3,
              max: 10,
              divisions: 14,
              onChanged: (value) => prefs.update(width: value),
            ),
            Container(
              height: 36,
              alignment: Alignment.center,
              child: Container(
                height: prefs.lineWidth,
                color: prefs.routeColor,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Масштаб при включении слежения · ${prefs.followZoom.round()}',
            ),
            Slider(
              value: prefs.followZoom,
              min: 14,
              max: 19,
              divisions: 5,
              onChanged: (value) => prefs.update(zoom: value),
            ),
            const Text(
              'Меньше — обзор района, больше — ближайшие повороты. На карте масштаб можно менять жестом.',
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: () => prefs.update(color: 0, width: 5.5, zoom: 17),
              child: const Text('Вернуть стандартный вид'),
            ),
          ],
        ),
      ),
    );
  }
}
