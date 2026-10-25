import 'package:flutter/material.dart';

import '../services/voice_guidance_service.dart';

class VoiceGuidanceSettings extends StatefulWidget {
  const VoiceGuidanceSettings({super.key});
  @override
  State<VoiceGuidanceSettings> createState() => _VoiceGuidanceSettingsState();
}

class _VoiceGuidanceSettingsState extends State<VoiceGuidanceSettings> {
  final _voice = VoiceGuidanceService.instance;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _voice.load();
      if (mounted) setState(() => _loaded = true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось загрузить настройки голоса'),
          ),
        );
      }
    }
  }

  Future<void> _change({bool? navigation, bool? reminders}) async {
    setState(() => _busy = true);
    try {
      await _voice.configure(navigation: navigation, reminders: reminders);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось сохранить настройки голоса'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _voice,
    builder: (context, _) => Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.record_voice_over_outlined),
          title: const Text('Озвучивать повороты'),
          subtitle: const Text(
            'Заранее и перед поворотом, при включённой навигации',
          ),
          value: _voice.navigationEnabled,
          onChanged: _loaded && !_busy && _voice.supported
              ? (value) => _change(navigation: value)
              : null,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.volume_up_outlined),
          title: const Text('Голосовые напоминания'),
          subtitle: const Text('Вода, этапы интервалов и отсечки дистанции'),
          value: _voice.remindersEnabled,
          onChanged: _loaded && !_busy && _voice.supported
              ? (value) => _change(reminders: value)
              : null,
        ),
        ListTile(
          leading: const Icon(Icons.play_circle_outline),
          title: const Text('Послушать голос'),
          subtitle: Text(
            _voice.error ?? 'Русский системный голос · громкость мультимедиа',
          ),
          onTap: !_loaded || _busy || !_voice.supported
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    await _voice.preview();
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
        ),
        if (_voice.error != null)
          ListTile(
            leading: const Icon(Icons.settings_voice),
            title: const Text('Настроить голос телефона'),
            subtitle: const Text(
              'Установите русский голос для работы без сети',
            ),
            onTap: () async {
              try {
                await _voice.openVoiceSettings();
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Откройте «Синтез речи» в настройках телефона',
                      ),
                    ),
                  );
                }
              }
            },
          ),
      ],
    ),
  );
}
