import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_update_service.dart';

/// Lets the user check, download, verify, and install an Android release.
Future<void> showAppUpdateDialog(
  BuildContext context, {
  bool showNoUpdate = true,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _AppUpdateDialog(showNoUpdate: showNoUpdate),
  );
}

class _AppUpdateDialog extends StatefulWidget {
  const _AppUpdateDialog({required this.showNoUpdate});

  final bool showNoUpdate;

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  AppRelease? _release;
  bool _checking = true;
  bool _working = false;
  double _progress = 0;
  bool _needsInstallPermission = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final release = await AppUpdateService.availableRelease();
      if (!mounted) return;
      setState(() {
        _release = release;
        _checking = false;
      });
      if (release == null && !widget.showNoUpdate) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _checking = false;
          _error = 'Не удалось проверить обновления. Проверьте интернет и повторите.';
        });
      }
    }
  }

  Future<void> _downloadAndInstall() async {
    final release = _release;
    if (release == null || _working) return;
    setState(() {
      _working = true;
      _error = null;
      _needsInstallPermission = false;
      _progress = 0;
    });
    try {
      final apk = await AppUpdateService.download(
        release,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      final started = await AppUpdateService.launchInstaller(apk);
      if (!mounted) return;
      if (started) {
        Navigator.of(context).pop();
      } else {
        setState(() {
          _working = false;
          _needsInstallPermission = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _working = false;
          _error = 'Не удалось скачать или проверить APK. Повторите попытку.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final release = _release;
    return AlertDialog(
      title: const Text('Обновление PulsePath'),
      content: SizedBox(
        width: 360,
        child: _checking
            ? const Row(
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 16),
                  Expanded(child: Text('Проверяем доступные версии…')),
                ],
              )
            : _error != null
            ? Text(_error!)
            : release == null
            ? const Text('У вас установлена последняя версия.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Доступна версия ${release.versionName}'),
                  if (release.notes.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(release.notes),
                  ],
                  if (_working) ...[
                    const SizedBox(height: 20),
                    LinearProgressIndicator(value: _progress),
                    const SizedBox(height: 8),
                    Text('Загрузка: ${(_progress * 100).round()}%'),
                  ],
                  if (_needsInstallPermission) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Разрешите установку неизвестных приложений для PulsePath в настройках Android, затем нажмите «Установить» ещё раз.',
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
        if (_error != null && !_checking)
          TextButton(
            onPressed: _working ? null : _check,
            child: const Text('Повторить'),
          ),
        if (release != null && !_checking && _error == null)
          FilledButton(
            onPressed: _working ? null : _downloadAndInstall,
            child: Text(
              _needsInstallPermission ? 'Установить' : 'Скачать и установить',
            ),
          ),
      ],
    );
  }
}
