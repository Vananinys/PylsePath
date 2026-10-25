import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/satellite_map.dart';

class SatelliteSettingsScreen extends StatefulWidget {
  const SatelliteSettingsScreen({super.key});
  @override
  State<SatelliteSettingsScreen> createState() =>
      _SatelliteSettingsScreenState();
}

class _SatelliteSettingsScreenState extends State<SatelliteSettingsScreen> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _message;
  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await SatelliteMap.configure(_key.text.trim());
      if (mounted) {
        _key.clear();
        setState(
          () => _message =
              'Спутниковый слой подключён. Выберите его кнопкой слоёв карты.',
        );
      }
    } catch (e) {
      if (mounted)
        setState(
          () => _message = e is FormatException
              ? e.message
              : 'Не удалось проверить ключ. Проверьте интернет.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Спутниковая карта')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.satellite_alt, size: 60),
        const SizedBox(height: 16),
        const Text(
          'Подключение MapTiler',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        const Text(
          'Создайте аккаунт MapTiler Cloud, выберите подходящий тариф и скопируйте API key. '
          'Ключ проверяется перед сохранением и хранится только на этом устройстве. '
          'При просмотре снимков сервис получает область карты и IP-адрес. Действуют условия и лимиты MapTiler.',
        ),
        TextButton(
          onPressed: () => launchUrl(
            Uri.parse('https://cloud.maptiler.com/account/keys/'),
            mode: LaunchMode.externalApplication,
          ),
          child: const Text('Открыть MapTiler Cloud'),
        ),
        TextField(
          controller: _key,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'MapTiler API key'),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Проверка…' : 'Проверить и подключить'),
        ),
        if (SatelliteMap.template != null)
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    await SatelliteMap.remove();
                    if (mounted)
                      setState(() => _message = 'Спутниковый слой отключён.');
                  },
            child: const Text('Удалить ключ с устройства'),
          ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(_message!),
          ),
      ],
    ),
  );
}
