import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/user_scope.dart';
import '../data/progress_backup_repository.dart';
import '../data/workout_history_repository.dart';
import '../services/owner_service.dart';
import '../services/recording_daily_activity_service.dart';
import '../services/background_location_service.dart';
import '../services/push_service.dart';
import '../services/developer_scenarios.dart';
import 'heatmap_explorer_screen.dart';
import 'progress_backup_screen.dart';

class DeveloperPanel extends StatefulWidget {
  const DeveloperPanel({super.key});
  @override
  State<DeveloperPanel> createState() => _DeveloperPanelState();
}

class _DeveloperPanelState extends State<DeveloperPanel> {
  final _results = <String, String>{};
  bool _allowed = false, _loading = true, _busy = false;
  String? _authorizedOwner;
  String _version = '—';
  String? _notice;
  @override
  void initState() {
    super.initState();
    _authorize();
  }

  Future<void> _authorize() async {
    try {
      final owner = UserScope.currentUserId();
      final rights = await OwnerService().entitlements().timeout(
        const Duration(seconds: 8),
      );
      final info = await PackageInfo.fromPlatform();
      if (mounted)
        setState(() {
          _allowed =
              owner != null &&
              owner == UserScope.currentUserId() &&
              rights['is_owner'] == true;
          _authorizedOwner = _allowed ? owner : null;
          _version = '${info.version} (${info.buildNumber})';
        });
    } catch (_) {
      if (mounted)
        setState(
          () => _notice = 'Не удалось проверить доступ. Нужен интернет.',
        );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(String name, Future<String> Function() action) async {
    if (_busy || !_allowed) return;
    final owner = UserScope.currentUserId();
    setState(() {
      _busy = true;
      _results[name] = 'Проверка…';
    });
    try {
      if (owner == null ||
          owner != _authorizedOwner ||
          owner != UserScope.currentUserId())
        throw StateError('access');
      final result = await action().timeout(const Duration(seconds: 35));
      if (mounted && owner == UserScope.currentUserId())
        setState(() => _results[name] = result);
    } catch (error) {
      if (mounted)
        setState(
          () => _results[name] = error is TimeoutException
              ? 'Превышено время ожидания. Можно повторить.'
              : 'Проверка не выполнена (${error.runtimeType}). Проверьте доступ и разрешения.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _gps() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    final permission = await Geolocator.checkPermission();
    if (!enabled ||
        permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever)
      return 'Служба: ${enabled ? 'включена' : 'выключена'} · разрешение: ${permission.name}. Откройте карту и нажмите GPS.';
    final fix = await Geolocator.getCurrentPosition(
      timeLimit: const Duration(seconds: 20),
    );
    return 'Точность ±${fix.accuracy.round()} м · возраст ${DateTime.now().difference(fix.timestamp).inSeconds} с';
  }

  Future<String> _steps() async {
    final steps = DailyActivityService.instance;
    await steps.refresh();
    return 'Recording API: ${steps.available ? 'доступен' : 'недоступен'} · ${steps.enabled ? 'сбор включён' : 'сбор выключен'} · разрешение ${steps.permissionGranted ? 'есть' : 'нет'} · ${steps.steps} шагов сегодня';
  }

  Future<String> _backup() async {
    final history = WorkoutHistoryRepository();
    await history.load();
    final state = await ProgressBackupRepository().read();
    return 'На телефоне: ${history.workoutHistory.length} заездов, ${history.unsyncedWorkouts.length} ждут отправки\nКопия: ${state['cloudSyncedAt'] ?? 'ещё не создана'} · ${(state['days'] as Map? ?? {}).length} дней · ${(state['unlocked'] as Map? ?? {}).length} достижений';
  }

  Future<String> _background() async {
    final service = BackgroundLocationService.instance;
    await service.refreshStatus();
    return 'Поддержка: ${service.supported ? 'есть' : 'нет'} · ${service.enabled ? 'включено' : 'выключено'} · ${service.running ? 'служба работает' : 'служба не запущена'}\n${service.notice ?? 'Ошибок состояния нет'}';
  }

  Future<String> _suite() async {
    final report = <String>[];
    for (final check in <(String, Future<String> Function())>[
      ('Кэш', _backup),
      ('Шаги', _steps),
      ('Фон', _background),
    ]) {
      try {
        report.add(
          '${check.$1}: ${await check.$2().timeout(const Duration(seconds: 8))}',
        );
      } catch (e) {
        report.add('${check.$1}: ${e.runtimeType}');
      }
    }
    report.add('Уведомления и GPS проверяются отдельными кнопками.');
    return report.join('\n\n');
  }

  @override
  Widget build(BuildContext context) => _loading
      ? const Center(child: CircularProgressIndicator())
      : !_allowed
      ? Center(
          child: TextButton(
            onPressed: _authorize,
            child: Text(_notice ?? 'Доступ только владельцу приложения.'),
          ),
        )
      : ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Панель разработчика · $_version',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Проверки работают на этом телефоне. Демонстрационные маршруты открываются отдельно и не записываются в вашу историю.',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run('Комплексная проверка', _suite),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Проверить приложение'),
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _run('GPS', _gps),
                  icon: const Icon(Icons.gps_fixed),
                  label: const Text('GPS'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _run('Шаги', _steps),
                  icon: const Icon(Icons.directions_walk),
                  label: const Text('Шаги'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run('Локальная копия', _backup),
                  icon: const Icon(Icons.storage),
                  label: const Text('Кэш'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run('Фоновая геолокация', _background),
                  icon: const Icon(Icons.location_on_outlined),
                  label: const Text('Фон'),
                ),
              ],
            ),
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Тест системного уведомления'),
              subtitle: const Text('Появится в шторке телефона'),
              onTap: _busy
                  ? null
                  : () => _run('Уведомление', () async {
                      final sent = await PushService.instance
                          .showDeveloperNotification();
                      return sent
                          ? 'Запрос отправлен системе. Проверьте шторку телефона.'
                          : 'Системе не дано разрешение на уведомления.';
                    }),
            ),
            ListTile(
              leading: const Icon(Icons.local_fire_department_outlined),
              title: const Text('Тестовая тепловая карта'),
              subtitle: const Text(
                'Повторные маршруты, разные виды спорта, даты и разрыв GPS',
              ),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => RideHeatmapScreen(
                    previewRides: DeveloperScenarios.heatmap(),
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_sync),
              title: const Text('Синхронизация и восстановление'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProgressBackupScreen()),
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            for (final result in _results.entries)
              Card(
                child: ListTile(
                  title: Text(result.key),
                  subtitle: SelectableText(result.value),
                ),
              ),
            if (_results.isNotEmpty)
              TextButton.icon(
                onPressed: () async {
                  final report =
                      'PulsePath $_version\n${DateTime.now().toIso8601String()}\n${_results.entries.map((e) => '${e.key}\n${e.value}').join('\n\n')}';
                  await Clipboard.setData(ClipboardData(text: report));
                  if (mounted)
                    setState(
                      () => _notice = 'Отчёт скопирован. Координаты, токены и идентификаторы аккаунта в него не включаются.',
                    );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Скопировать отчёт'),
              ),
            if (_notice != null)
              Padding(padding: const EdgeInsets.all(12), child: Text(_notice!)),
          ],
        );
}
