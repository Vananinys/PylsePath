import 'package:flutter/material.dart';

import '../data/user_scope.dart';
import '../data/progress_backup_repository.dart';
import '../data/workout_history_repository.dart';
import '../data/progress_goals_repository.dart';
import '../services/achievements_service.dart';
import '../services/recording_daily_activity_service.dart';
import '../services/legacy_progress_recovery.dart';

class ProgressBackupScreen extends StatefulWidget {
  const ProgressBackupScreen({super.key});
  @override
  State<ProgressBackupScreen> createState() => _ProgressBackupScreenState();
}

class _ProgressBackupScreenState extends State<ProgressBackupScreen> {
  bool _busy = false;
  String? _message;
  Map<String, dynamic> _state = {};
  int _legacy = 0;
  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    final owner = UserScope.currentUserId();
    final state = await ProgressBackupRepository().read();
    final legacy = await LegacyProgressRecovery().pending();
    if (mounted && UserScope.currentUserId() == owner)
      setState(() {
        _state = state;
        _legacy = legacy.length;
      });
  }

  Future<void> _sync() async {
    final owner = UserScope.currentUserId();
    if (owner == null) {
      setState(() => _message = 'Войдите в свой аккаунт');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final history = WorkoutHistoryRepository();
      await history.load();
      await history.retryUnsynced(maxItems: 25);
      await history.restoreFromCloud();
      if (UserScope.currentUserId() != owner) return;
      await AchievementsService.captureProgress(history.workoutHistory);
      await ProgressBackupRepository().sync();
      if (UserScope.currentUserId() != owner) return;
      await AchievementsService.restoreProgress();
      await DailyActivityService.instance.restoreCloudBackup();
      await ProgressGoalsRepository().load();
      if (mounted)
        setState(
          () => _message = history.hasPendingSync
              ? 'Часть заездов ещё ждёт отправки. Повторите синхронизацию.'
              : 'Облачная копия обновлена. История восстановлена.',
        );
    } catch (_) {
      if (mounted)
        setState(
          () => _message = 'Отправка отложена. Данные сохранены на телефоне; повторим при подключении.',
        );
    } finally {
      await _read();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recover() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Это ваши старые записи?'),
        content: const Text(
          'Найдены данные старой версии без привязки к аккаунту. Подтвердите, что это ваши заезды и шаги. Они будут добавлены в текущий аккаунт; исходная копия останется на телефоне.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Да, восстановить мои записи'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await LegacyProgressRecovery().recover(confirmedOwnership: true);
      await DailyActivityService.instance.restoreCloudBackup();
      await _sync();
    } catch (_) {
      if (mounted)
        setState(
          () => _message = 'Не все старые записи удалось прочитать. Исходные данные сохранены; можно повторить.',
        );
    } finally {
      await _read();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Резервная копия')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.cloud_done_outlined, size: 54),
        const SizedBox(height: 16),
        Text(
          'Ваш прогресс с вами',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        const Text(
          'Заезды, шаги, цели и заработанные достижения сохраняются на телефоне. При открытом приложении и подключении к интернету копия отправляется в ваш аккаунт и восстанавливается после входа на другом устройстве.',
        ),
        const SizedBox(height: 16),
        Text(
          _state['pending'] == true
              ? 'Есть изменения, ожидающие отправки'
              : _state['cloudSyncedAt'] != null
              ? 'Облачная копия сохранена'
              : 'Облачная копия ещё не создана',
        ),
        if (_state['cloudSyncedAt'] is String)
          Text(
            'Последняя синхронизация: ${DateTime.tryParse(_state['cloudSyncedAt'])?.toLocal().toString().split('.').first ?? '—'}',
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _sync,
          icon: const Icon(Icons.sync),
          label: Text(
            _busy ? 'Синхронизация…' : 'Сохранить и восстановить из облака',
          ),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(_message!),
          ),
        if (_legacy > 0) ...[
          const Divider(height: 32),
          const Text('Найдены записи старой версии'),
          OutlinedButton(
            onPressed: _busy ? null : _recover,
            child: const Text('Проверить и восстановить старые записи'),
          ),
        ],
        const SizedBox(height: 16),
        const Text(
          'Для восстановления нужен тот же аккаунт. Если удалить приложение до отправки данных, неотправленные записи могут быть потеряны.',
        ),
      ],
    ),
  );
}
