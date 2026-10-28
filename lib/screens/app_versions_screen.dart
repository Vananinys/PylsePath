import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update_service.dart';

class AppVersionsScreen extends StatefulWidget {
  const AppVersionsScreen({super.key, this.loadReleases, this.installedCode});
  final Future<List<AppRelease>> Function(UpdateChannel)? loadReleases;
  final int? installedCode;
  @override
  State<AppVersionsScreen> createState() => _AppVersionsScreenState();
}

class _AppVersionsScreenState extends State<AppVersionsScreen> {
  UpdateChannel _channel = UpdateChannel.stable;
  List<AppRelease> _releases = [];
  int _installed = 0;
  bool _loading = true;
  String? _error;
  int? _busy;
  double _progress = 0;
  final Map<int, File> _downloaded = {};

  @override
  void initState() {
    super.initState();
    _initialise();
  }

  Future<void> _initialise() async {
    try {
      final channel = await AppUpdateService.selectedChannel();
      final installed =
          widget.installedCode ?? await AppUpdateService.installedVersionCode();
      if (!mounted) return;
      setState(() {
        _channel = channel;
        _installed = installed;
      });
      await _reload();
    } catch (_) {
      if (mounted)
        setState(() {
          _error = 'Не удалось прочитать настройки обновлений';
          _loading = false;
        });
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final releases =
          await (widget.loadReleases?.call(_channel) ??
              AppUpdateService.releaseHistory(channel: _channel));
      if (mounted)
        setState(() {
          _releases = releases;
          _loading = false;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
          _error =
              'Не удалось загрузить версии. Проверьте соединение и повторите.';
        });
    }
  }

  Future<void> _changeChannel(UpdateChannel channel) async {
    if (_busy != null || _loading || channel == _channel) return;
    if (channel == UpdateChannel.beta) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Участвовать в бета-тесте?'),
          content: const Text(
            'Бета-версии получают новые функции раньше и могут содержать ошибки. Выход из бета-канала меняет будущие обновления. Если стабильная версия старше установленной, дождитесь нового стабильного выпуска: Android не разрешает обычное понижение номера сборки. Данные приложения удалять не нужно.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Включить бета-канал'),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
    }
    try {
      await AppUpdateService.selectChannel(channel);
      if (!mounted) return;
      setState(() => _channel = channel);
      await _reload();
    } catch (_) {
      _message('Не удалось сохранить выбор канала');
    }
  }

  void _message(String value) {
    if (mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _download(AppRelease release) async {
    if (_busy != null) return;
    setState(() {
      _busy = release.versionCode;
      _progress = 0;
    });
    try {
      final file = await AppUpdateService.download(
        release,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      if (mounted) setState(() => _downloaded[release.versionCode] = file);
      _message('APK скачан и проверен по SHA-256');
    } catch (_) {
      _message('Не удалось скачать или проверить APK. Повторите попытку.');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _install(AppRelease release) async {
    if (release.versionCode < _installed || _busy != null) return;
    final file = _downloaded[release.versionCode];
    if (file == null) return;
    try {
      final started = await AppUpdateService.launchInstaller(file);
      if (!started)
        _message(
          'Разрешите установку для PulsePath в настройках Android и нажмите «Установить» ещё раз',
        );
    } catch (_) {
      _message('Android не смог открыть установщик');
    }
  }

  Widget _card(AppRelease release) {
    final old = release.versionCode < _installed;
    final ready = _downloaded.containsKey(release.versionCode);
    final busy = _busy == release.versionCode;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${release.versionName} · ${release.channel == UpdateChannel.beta ? 'Бета' : 'Стабильная'}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (release.versionCode == _installed)
              const Text('Установлена сейчас'),
            if (release.notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(release.notes),
              ),
            if (old)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Архивный APK можно скачать и сохранить. Установка поверх более новой версии Android недоступна.',
                ),
              ),
            if (busy)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(value: _progress),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!ready)
                  FilledButton.tonalIcon(
                    onPressed: _busy == null && AppUpdateService.supported
                        ? () => _download(release)
                        : null,
                    icon: const Icon(Icons.download),
                    label: Text(old ? 'Скачать старую версию' : 'Скачать APK'),
                  ),
                if (ready && !old)
                  FilledButton(
                    onPressed: _busy == null ? () => _install(release) : null,
                    child: const Text('Установить'),
                  ),
                if (ready)
                  OutlinedButton(
                    onPressed: _busy == null
                        ? () async {
                            try {
                              await SharePlus.instance.share(
                                ShareParams(
                                  files: [
                                    XFile(
                                      _downloaded[release.versionCode]!.path,
                                    ),
                                  ],
                                ),
                              );
                            } catch (_) {
                              _message('Не удалось открыть отправку файла');
                            }
                          }
                        : null,
                    child: const Text('Сохранить / поделиться APK'),
                  ),
                if (release.sourceCommit != null)
                  TextButton(
                    onPressed: () => launchUrl(
                      Uri.parse(
                        'https://github.com/Vananinys/PylsePath/commit/${release.sourceCommit}',
                      ),
                      mode: LaunchMode.externalApplication,
                    ),
                    child: const Text('Исходный код выпуска'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _busy == null,
    child: Scaffold(
      appBar: AppBar(title: const Text('Версии приложения')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Какие обновления получать',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            SegmentedButton<UpdateChannel>(
              segments: const [
                ButtonSegment(
                  value: UpdateChannel.stable,
                  label: Text('Стабильные'),
                ),
                ButtonSegment(value: UpdateChannel.beta, label: Text('Бета')),
              ],
              selected: {_channel},
              onSelectionChanged: _busy != null || _loading
                  ? null
                  : (value) => _changeChannel(value.single),
            ),
            const SizedBox(height: 12),
            Text(
              _channel == UpdateChannel.beta
                  ? 'Показываем бета- и стабильные выпуски. Счётчики использования включаются отдельно.'
                  : 'Только проверенные стабильные выпуски. Выбор канала не переустанавливает приложение.',
            ),
            const SizedBox(height: 16),
            if (_loading)
              const LinearProgressIndicator()
            else if (_error != null) ...[
              Text(_error!),
              TextButton(onPressed: _reload, child: const Text('Повторить')),
            ] else if (_releases.isEmpty)
              const Text('Опубликованных версий пока нет')
            else ...[
              if (_channel == UpdateChannel.beta &&
                  !_releases.any((r) => r.channel == UpdateChannel.beta))
                const Text('Бета-выпусков пока нет. Новые появятся здесь.'),
              _card(_releases.first),
              if (_releases.length > 1)
                ExpansionTile(
                  title: const Text('Предыдущие версии'),
                  children: [
                    for (final release in _releases.skip(1)) _card(release),
                  ],
                ),
            ],
            TextButton.icon(
              onPressed: AppUpdateService.openReleasesPage,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Все выпуски на GitHub'),
            ),
          ],
        ),
      ),
    ),
  );
}
