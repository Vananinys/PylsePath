import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/background_location_service.dart';

class BackgroundLocationSettings extends StatefulWidget {
  const BackgroundLocationSettings({
    super.key,
    required this.shareAllowed,
    this.service,
  });
  final bool shareAllowed;
  final BackgroundLocationService? service;
  @override
  State<BackgroundLocationSettings> createState() =>
      _BackgroundLocationSettingsState();
}

class _BackgroundLocationSettingsState extends State<BackgroundLocationSettings>
    with WidgetsBindingObserver {
  BackgroundLocationService get service =>
      widget.service ?? BackgroundLocationService.instance;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(service.refreshStatus());
    _poll();
  }

  void _poll() {
    _timer?.cancel();
    if (!service.supported) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (service.enabled && !service.busy) unawaited(service.refreshStatus());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(service.refreshStatus());
      _poll();
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!service.supported) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.location_on_outlined),
            title: const Text('Местоположение при закрытом приложении'),
            subtitle: Text(
              !widget.shareAllowed
                  ? 'Сначала включите трансляцию позиции друзьям'
                  : service.busy
                  ? 'Подключаем фоновое обновление…'
                  : 'Друзья видят обновления без заезда. Экономный режим, примерно раз в минуту при перемещении. Постоянное системное уведомление.',
            ),
            value: service.enabled,
            onChanged:
                service.ready &&
                    !service.busy &&
                    (widget.shareAllowed || service.enabled)
                ? service.setEnabled
                : null,
          ),
          if (service.enabled && service.running)
            const Padding(
              padding: EdgeInsets.fromLTRB(72, 0, 16, 8),
              child: Text(
                'Фоновая геолокация работает',
                style: TextStyle(color: Colors.green),
              ),
            ),
          if (service.lastPublishedAt != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
              child: Text(
                'Последняя передача: ${MaterialLocalizations.of(context).formatShortDate(service.lastPublishedAt!)} '
                '${TimeOfDay.fromDateTime(service.lastPublishedAt!).format(context)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (service.notice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    service.notice!,
                    style: const TextStyle(color: Colors.deepOrange),
                  ),
                  const TextButton(
                    onPressed: openAppSettings,
                    child: Text('Разрешения телефона'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
