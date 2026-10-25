import 'package:flutter/material.dart';

import 'dart:async';

import '../data/workout_history_repository.dart';
import '../models/saved_route.dart';
import '../models/workout_record.dart';
import '../services/rides_service.dart';
import 'workout_detail_screen.dart';
import '../widgets/route_trace_preview.dart';

class WorkoutHistoryScreen extends StatefulWidget {
  const WorkoutHistoryScreen({super.key});

  @override
  State<WorkoutHistoryScreen> createState() => _WorkoutHistoryScreenState();
}

class _WorkoutHistoryScreenState extends State<WorkoutHistoryScreen> {
  final WorkoutHistoryRepository _repository = WorkoutHistoryRepository();
  final RidesService _ridesService = RidesService();
  bool _isLoading = true;
  List<SavedRoute> _routes = [];
  bool _hasUnsynced = false;

  @override
  void initState() {
    super.initState();
    _loadRoutes();
  }

  /// [mergeCloud] = true — подтянуть все страницы истории из Supabase (`rides`),
  /// отправить очередь офлайн-заездов и сверить полный серверный снимок с кэшем.
  /// Неотправленные локальные тренировки при такой сверке сохраняются.
  Future<void> _loadRoutes({bool mergeCloud = true}) async {
    setState(() => _isLoading = true);

    List<SavedRoute> remote = const [];
    try {
      if (mergeCloud) {
        // История, очередь досылки и облачные заезды — параллельно.
        await _repository.load();
        await _repository.retryUnsynced();
        remote = await _ridesService.fetchRides(throwOnError: true);
      } else {
        await _repository.load();
      }
      if (mergeCloud) {
        // Missing cloud rows are not proof of deletion. Only explicit local
        // deletion actions create tombstones; restoration preserves the archive.
        await _repository.mergeRemote(remote);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось загрузить историю: $error')),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      // workoutHistoryDesc сортирует по дате заезда (свежие первыми),
      // что равнозначно серверной сортировке created_at DESC.
      _routes = _repository.workoutHistoryDesc.toList();
      _hasUnsynced = _repository.unsyncedWorkouts.isNotEmpty;
      _isLoading = false;
    });
    if (mergeCloud) unawaited(_refreshWalkingSteps());
  }

  Future<void> _refreshWalkingSteps() async {
    try {
      final changed = await _repository.reconcileWalkingSteps();
      if (mounted && changed > 0)
        setState(() => _routes = _repository.workoutHistoryDesc.toList());
    } catch (_) {
      /* Saved steps stay available offline. */
    }
  }

  // Рассчитываем итоговую статистику (парсинг строк живёт в SavedRoute)
  double get _totalKm =>
      _routes.fold(0.0, (sum, item) => sum + item.distanceKm);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('История заездов'), centerTitle: true),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _routes.isEmpty
          ? _buildEmptyState()
          : Column(
              children: [
                _buildSummaryHeader(),
                if (_hasUnsynced)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Некоторые заезды ещё не отправлены в облако — '
                      'они уедут при следующем открытии истории с интернетом.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _routes.length,
                    padding: const EdgeInsets.all(12),
                    itemBuilder: (context, index) {
                      final route = _routes[index];
                      return _buildRouteCard(route);
                    },
                  ),
                ),
              ],
            ),
    );
  }

  // Плашка с общей статистикой (Всего км, Заездов)
  Widget _buildSummaryHeader() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).primaryColor.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatColumn(
            'Общий пробег',
            '${_totalKm.toStringAsFixed(2)} км',
            Icons.straighten,
          ),
          Container(width: 1, height: 40, color: Colors.grey.shade300),
          _buildStatColumn(
            'Всего заездов',
            '${_routes.length}',
            Icons.directions_bike,
          ),
        ],
      ),
    );
  }

  Widget _buildStatColumn(String label, String value, IconData icon) {
    return Column(
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: Theme.of(context).primaryColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  // Элемент списка с одним заездом
  Widget _buildRouteCard(SavedRoute route) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: route.routePoints.length >= 2
            ? SizedBox(
                width: 52,
                height: 52,
                child: RouteTracePreview(
                  points: route.routePoints,
                  segmentStarts: route.workoutDetails.segmentStarts,
                ),
              )
            : CircleAvatar(
                backgroundColor: Colors.deepOrange.withValues(alpha: 0.15),
                child: const Icon(
                  Icons.directions_bike,
                  color: Colors.deepOrange,
                ),
              ),
        title: Text(
          route.title.isNotEmpty ? route.title : 'Заезд',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Дата заезда: без неё карточки с одинаковым названием неразличимы.
              Text(
                _formatDate(route.dateTime),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 4),
              if (route.workoutDetails.rideMoments.isNotEmpty)
                Text(
                  'Личных мест: ${route.workoutDetails.rideMoments.length}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff147d73),
                  ),
                ),
              Row(
                children: [
                  const Icon(Icons.route, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    route.distance,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(width: 12),
                  const Icon(Icons.timer, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(route.displayDuration),
                ],
              ),
            ],
          ),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          onPressed: () => _confirmRemove(route),
        ),
        onTap: () async {
          final workout = WorkoutRecord.fromSavedRoute(route);
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => WorkoutDetailScreen(workout: workout),
            ),
          );
          if (mounted) await _loadRoutes(mergeCloud: false);
        },
      ),
    );
  }

  // Удаление с подтверждением: заезд синхронизируется с облаком, случайный
  // тап по корзине не должен удалять запись безвозвратно.
  Future<void> _confirmRemove(SavedRoute route) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить заезд?'),
        content: Text(
          '«${route.title.isNotEmpty ? route.title : 'Заезд'}» будет удалён из истории.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _repository.removeWorkout(route);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось удалить заезд: $error')),
        );
      }
      return;
    }
    // Без merge: иначе только что удалённый локально заезд вернулся
    // бы из облака при обновлении списка.
    if (mounted) _loadRoutes(mergeCloud: false);
  }

  String _formatDate(DateTime date) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(date.day)}.${two(date.month)}.${date.year} '
        '${two(date.hour)}:${two(date.minute)}';
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'История заездов пуста',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Завершите свободный заезд, чтобы сохранить результаты',
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
