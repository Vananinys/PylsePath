import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Appearance is local to this installation and never changes profile privacy.
class AppAppearance extends ChangeNotifier {
  AppAppearance();
  static final instance = AppAppearance();
  static const preferenceKey = 'interface_theme_mode_v1';
  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    _mode =
        ThemeMode.values
            .where((mode) => mode.name == preferences.getString(preferenceKey))
            .firstOrNull ??
        ThemeMode.system;
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(preferenceKey, mode.name)) {
      throw StateError('Не удалось сохранить тему');
    }
    _mode = mode;
    notifyListeners();
  }
}

class AppearanceSetting extends StatelessWidget {
  const AppearanceSetting({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppAppearance.instance,
    builder: (context, _) => ListTile(
      leading: const Icon(Icons.contrast),
      title: const Text('Тема приложения'),
      subtitle: Text(_label(AppAppearance.instance.mode)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (sheetContext) => ListenableBuilder(
          listenable: AppAppearance.instance,
          builder: (context, _) => SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Тема приложения',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Системная тема меняется вместе с настройками телефона.',
                  ),
                  const SizedBox(height: 12),
                  for (final mode in ThemeMode.values)
                    ListTile(
                      leading: Icon(switch (mode) {
                        ThemeMode.system => Icons.brightness_auto_outlined,
                        ThemeMode.light => Icons.light_mode_outlined,
                        ThemeMode.dark => Icons.dark_mode_outlined,
                      }),
                      title: Text(_label(mode)),
                      selected: AppAppearance.instance.mode == mode,
                      trailing: AppAppearance.instance.mode == mode
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () async {
                        try {
                          await AppAppearance.instance.setMode(mode);
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        } catch (_) {
                          if (context.mounted)
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Не удалось сохранить тему. Попробуйте ещё раз.',
                                ),
                              ),
                            );
                        }
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  static String _label(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'Как на телефоне',
    ThemeMode.light => 'Светлая',
    ThemeMode.dark => 'Тёмная',
  };
}
