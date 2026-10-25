import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../widgets/pulsepath_logo.dart';
import 'privacy_screen.dart';

/// Экран «О приложении»: версия, назначение, чем можно помочь проекту.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('О приложении'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 8),
          Center(
            child: Column(
              children: [
                const PulsePathLogo(size: 72, radius: 20),
                const SizedBox(height: 12),
                const Text(
                  'PulsePath',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const _VersionText(),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'GPS-трекер для велосипедистов и не только: запись заездов с '
            'автопаузой и уклоном, маршруты с анализом покрытия, офлайн-карты, '
            'гараж техники, цели и достижения.',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 24),
          const Text(
            'Данные и приватность',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Профиль, заезды, гараж и прогресс синхронизируются с Supabase. '
            'Видимость полей профиля и передачу позиции друзьям можно настроить '
            'в приватности. Публикация маршрутов и сообщения раскрывают данные '
            'выбранным получателям. Внешние сервисы карт, поиска, погоды и '
            'уведомлений обрабатывают запросы для работы этих функций.',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          TextButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PrivacyScreen()),
            ),
            icon: const Icon(Icons.policy_outlined),
            label: const Text('Данные и согласия'),
          ),
          const SizedBox(height: 24),
          const Text(
            'Поддержать проект',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Приложение развивается энтузиастом. Самая большая помощь — '
            'рассказать о нём друзьям-велосипедистам и оставить отзыв.',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _VersionText extends StatefulWidget {
  const _VersionText();

  @override
  State<_VersionText> createState() => __VersionTextState();
}

class __VersionTextState extends State<_VersionText> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _version = 'Версия ${info.version} (${info.buildNumber})');
    } catch (_) {
      // Версия недоступна — просто не показываем строку.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_version == null) return const SizedBox.shrink();
    return Text(
      _version!,
      style: const TextStyle(fontSize: 13, color: Colors.grey),
    );
  }
}
