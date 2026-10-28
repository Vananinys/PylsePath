import 'package:flutter/material.dart';

import '../state/profile_provider.dart';
import 'navigation_preferences_screen.dart';
import 'profile_screen.dart';
import 'trail_appearance_screen.dart';
import 'owned_trail_style_screen.dart';

/// One entry point for the existing appearance editors; their storage stays intact.
class CustomizationScreen extends StatelessWidget {
  const CustomizationScreen({super.key, this.provider, this.interfaceSettings});
  final ProfileProvider? provider;
  final Widget? interfaceSettings;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Кастомизация')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Сделайте PulsePath своим',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text('Оформление профиля, следов и карты — в одном месте.'),
        const SizedBox(height: 20),
        _tile(
          context,
          Icons.auto_awesome,
          'Мой шлейф',
          'Вы выбираете оформление, друзья видят ваш выбор',
          () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const OwnedTrailStyleScreen()),
          ),
        ),
        _tile(
          context,
          Icons.gesture,
          'Следы маршрутов и видимость',
          'Оформление записанных путей и показ шлейфов на вашем экране',
          () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const TrailAppearanceScreen()),
          ),
        ),
        if (provider != null)
          _tile(
            context,
            Icons.face_retouching_natural,
            'Оформление профиля',
            'Аватар, рамка, обложка, цвет и витрина наград',
            () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ProfileScreen(provider: provider!, customizeOnOpen: true),
              ),
            ),
          ),
        _tile(
          context,
          Icons.palette_outlined,
          'Линия маршрута',
          'Цвет и толщина обычной линии; масштаб слежения',
          () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const NavigationPreferencesScreen(),
            ),
          ),
        ),
        if (interfaceSettings != null) interfaceSettings!,
      ],
    ),
  );

  Widget _tile(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: ListTile(
      contentPadding: const EdgeInsets.all(16),
      leading: Icon(
        icon,
        size: 30,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
}
