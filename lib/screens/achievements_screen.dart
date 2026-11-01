import 'package:flutter/material.dart';

import '../data/workout_history_repository.dart';
import '../models/saved_route.dart';
import '../services/achievements_service.dart';
import '../services/personal_records.dart';
import '../services/owner_service.dart';
import '../services/profile_presentation_service.dart';
import '../data/user_scope.dart';
import '../models/activity_type.dart';
import '../models/workout_record.dart';
import 'workout_detail_screen.dart';
import '../services/achievement_journey.dart';
import '../widgets/achievement_hub.dart';
import '../models/owner_award.dart';

/// Экран достижений: личные рекорды по истории заездов + бейджи-пороги.
class AchievementsScreen extends StatefulWidget {
  const AchievementsScreen({super.key, this.useLegacyLayout = false});

  /// Retains the previous layout for compatibility without removing its code.
  final bool useLegacyLayout;

  @override
  State<AchievementsScreen> createState() => _AchievementsScreenState();
}

class _AchievementsScreenState extends State<AchievementsScreen> {
  final WorkoutHistoryRepository _repository = WorkoutHistoryRepository();
  bool _isLoading = true;
  List<SavedRoute> _rides = [];
  bool _catalogFailed = false;
  ActivityType? _recordActivity;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final owner = UserScope.currentUserId();
    AchievementsService.bindToUser(owner);
    await _repository.load();
    await AchievementsService.restoreProgress();
    if (mounted && owner == UserScope.currentUserId()) {
      setState(() {
        _rides = _repository.workoutHistory;
        _isLoading = false;
      });
    }
    try {
      await _repository.restoreFromCloud();
    } catch (_) {
      /* Keep local rides offline. */
    }
    await AchievementsService.captureProgress(_repository.workoutHistory);
    var failed = false;
    try {
      await OwnerService().catalog();
    } catch (_) {
      failed = true;
    }
    try {
      AchievementsService.ownerIssued = await OwnerService().awards();
    } catch (_) {
      failed = true;
    }
    if (owner != null) {
      try {
        await ProfilePresentationService().load(owner, refreshEarned: true);
      } catch (_) {
        failed = true;
      }
    }
    if (!mounted || owner != UserScope.currentUserId()) return;
    setState(() {
      _rides = _repository.workoutHistory;
      _catalogFailed = failed;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLoading && !widget.useLegacyLayout) {
      return AchievementHub(
        journey: AchievementJourney(_rides),
        onRefresh: _load,
        records: _buildRecords(),
        statistics: _buildSummary(),
        catalogFailed: _catalogFailed,
        titles: AchievementsService.ownerIssued
            .where((a) => a.kind == 'title')
            .toList(),
        onEquipTitle: _equipTitle,
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Достижения'), centerTitle: true),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_rides.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: Text(
                        'Ваши достижения впереди! Завершите первый заезд, чтобы открыть первую награду.',
                      ),
                    ),
                  _buildSummary(),
                  const SizedBox(height: 20),
                  if (_rides.isNotEmpty)
                    const Text(
                      'Личные рекорды',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  const SizedBox(height: 10),
                  _buildRecords(),
                  const SizedBox(height: 20),
                  const Text(
                    'Достижения',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  _buildBadges(),
                  if (_catalogFailed)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'Дополнительные достижения не загрузились. Потяните вниз, чтобы повторить.',
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Future<void> _equipTitle(OwnerAward award) async {
    final owner = UserScope.currentUserId();
    if (owner == null) return;
    final service = ProfilePresentationService();
    final style = await service.load(owner);
    if (UserScope.currentUserId() != owner) return;
    await service.save(style, award.id);
    await _load();
  }

  Widget _buildSummary() {
    final totalKm = AchievementsService.totalDistanceKm(_rides);
    final days = AchievementsService.activeDays(_rides);
    final streak = AchievementsService.weeklyStreak(_rides);
    final earned = AchievementsService.badges(_rides)
        .where((badge) => badge.earned)
        .length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.deepOrange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.deepOrange.withValues(alpha: 0.3)),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceAround,
        spacing: 16,
        runSpacing: 12,
        children: [
          _summaryItem(totalKm.toStringAsFixed(0), 'км всего'),
          _summaryItem(_rides.length.toString(), 'заездов'),
          _summaryItem('$streak', 'недель серия'),
          _summaryItem('$earned', 'достижений'),
          _summaryItem('$days', 'дней в седле'),
        ],
      ),
    );
  }

  Widget _summaryItem(String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.deepOrange,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildRecords() {
    final types = _rides.map((r) => r.activityType).toSet().toList();
    if (types.isEmpty) return const SizedBox.shrink();
    final activity = types.contains(_recordActivity)
        ? _recordActivity!
        : types.first;
    final records = PersonalRecords.calculate(
      _rides.where((r) => r.activityType == activity).toList(),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButton<ActivityType>(
          isExpanded: true,
          value: activity,
          items: types
              .map((a) => DropdownMenuItem(value: a, child: Text(a.label)))
              .toList(),
          onChanged: (a) => setState(() => _recordActivity = a),
        ),
        const Text(
          'Рекорды сравниваются внутри одного вида активности. Временные отрезки требуют непрерывных GPS-данных.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        for (final r in records)
          InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => WorkoutDetailScreen(
                  workout: WorkoutRecord.fromSavedRoute(r.ride),
                ),
              ),
            ),
            child: _recordCard(
              icon: r.key.startsWith('power')
                  ? Icons.bolt
                  : Icons.emoji_events_outlined,
              color: Colors.deepOrange,
              title: r.title,
              value: '${r.formatted} — ${r.ride.title}',
            ),
          ),
      ],
    );
  }

  Widget _recordCard({
    required IconData icon,
    required Color color,
    required String title,
    required String value,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBadges() {
    final badges = AchievementsService.badges(_rides);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisExtent: 170 * MediaQuery.textScalerOf(context).scale(1),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: badges.length,
      itemBuilder: (context, index) => _badgeCard(badges[index]),
    );
  }

  Widget _badgeCard(Achievement badge) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: badge.earned
            ? Colors.deepOrange.withValues(alpha: 0.08)
            : Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: badge.earned
              ? Colors.deepOrange.withValues(alpha: 0.5)
              : Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            badge.icon,
            style: TextStyle(
              fontSize: 28,
              color: badge.earned
                  ? null
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            badge.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: badge.earned
                  ? Theme.of(context).colorScheme.onSurface
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            badge.publicDescription,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: badge.earned
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
