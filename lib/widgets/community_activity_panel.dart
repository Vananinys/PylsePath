import 'package:flutter/material.dart';

import '../models/community_activity.dart';
import '../models/community_post.dart';
import '../models/workout_details.dart' show workoutTime;
import '../services/community_activity_service.dart';

class CommunityActivityPanel extends StatefulWidget {
  const CommunityActivityPanel({
    super.key,
    this.refreshToken = 0,
    this.onOpenHistory,
    this.onOpenPost,
    this.onOpenFriends,
    this.service,
  });
  final int refreshToken;
  final VoidCallback? onOpenHistory, onOpenFriends;
  final ValueChanged<CommunityPost>? onOpenPost;
  final CommunityActivityService? service;
  @override
  State<CommunityActivityPanel> createState() => _CommunityActivityPanelState();
}

class _CommunityActivityPanelState extends State<CommunityActivityPanel> {
  late final _service = widget.service ?? CommunityActivityService();
  late final _owner = _service.userId;
  CommunityWeekActivity? _week;
  List<CommunityPost>? _friends;
  bool _weekError = false, _friendsError = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CommunityActivityPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) _load();
  }

  void _load() {
    final generation = ++_generation;
    _loadWeek(generation);
    _loadFriends(generation);
  }

  bool _current(int generation) =>
      mounted &&
      _owner != null &&
      _owner == _service.userId &&
      generation == _generation;
  Future<void> _loadWeek(int generation) async {
    try {
      final week = await _service.loadMyWeek();
      if (_current(generation))
        setState(() {
          _week = week;
          _weekError = false;
        });
    } catch (_) {
      if (_current(generation)) setState(() => _weekError = true);
    }
  }

  Future<void> _loadFriends(int generation) async {
    try {
      final friends = await _service.loadFriendRides();
      if (_current(generation))
        setState(() {
          _friends = friends;
          _friendsError = false;
        });
    } catch (_) {
      if (_current(generation)) setState(() => _friendsError = true);
    }
  }

  Widget _retry(String text, VoidCallback retry) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(text),
      TextButton.icon(
        onPressed: retry,
        icon: const Icon(Icons.refresh),
        label: const Text('Повторить'),
      ),
    ],
  );
  Widget _metric(String value, String label) => Semantics(
    label: '$label: $value',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: Theme.of(context).textTheme.titleLarge),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    if (_owner == null || _service.userId != _owner)
      return const SizedBox.shrink();
    final week = _week;
    String shortDate(DateTime day) =>
        '${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Моя неделя',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (week != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 12),
                    child: Text(
                      '${shortDate(week.start)} — ${shortDate(week.end)}',
                    ),
                  ),
                if (_weekError)
                  _retry(
                    'Не удалось обновить активность',
                    () => _loadWeek(_generation),
                  )
                else if (week == null)
                  const LinearProgressIndicator()
                else ...[
                  if (week.count > 0)
                    Wrap(
                      spacing: 24,
                      runSpacing: 12,
                      children: [
                        _metric(
                          week.distanceKm == null
                              ? '—'
                              : '${week.distanceKm!.toStringAsFixed(1)} км',
                          'Дистанция',
                        ),
                        _metric(
                          week.activeSeconds == null
                              ? '—'
                              : workoutTime(
                                  Duration(seconds: week.activeSeconds!),
                                ),
                          'Время',
                        ),
                        _metric('${week.count}', 'Тренировок'),
                      ],
                    ),
                  if (week.count == 0)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('0 тренировок на этой неделе'),
                    ),
                  if (week.distanceKm == null || week.activeSeconds == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('В части записей нет точных показателей.'),
                    ),
                  if (widget.onOpenHistory != null)
                    TextButton(
                      onPressed: widget.onOpenHistory,
                      child: const Text('Моя активность'),
                    ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 4),
          title: Text(
            _friends == null
                ? 'Поездки друзей'
                : 'Поездки друзей (${_friends!.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          subtitle: Text(
            _friendsError
                ? 'Не удалось загрузить поездки друзей'
                : 'Заезды, которыми друзья поделились в сообществе',
          ),
          children: [
            if (_friendsError)
              _retry(
                'Не удалось загрузить поездки друзей',
                () => _loadFriends(_generation),
              )
            else if (_friends == null)
              const LinearProgressIndicator()
            else if (_friends!.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Пока нет опубликованных заездов друзей.'),
                    if (widget.onOpenFriends != null)
                      TextButton(
                        onPressed: widget.onOpenFriends,
                        child: const Text('Найти друзей'),
                      ),
                  ],
                ),
              )
            else
              ..._friends!.map((post) {
                final attachment = post.routeAttachment;
                final distance = attachment?.distanceKm ?? post.rideDistanceKm;
                final duration =
                    attachment?.durationSeconds ?? post.rideDurationSeconds;
                final validDistance =
                    distance != null && distance.isFinite && distance >= 0;
                return Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    title: Text(post.authorName),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          attachment?.title.isNotEmpty == true
                              ? attachment!.title
                              : 'Опубликованный заезд',
                        ),
                        Text(
                          '${validDistance ? '${distance.toStringAsFixed(1)} км' : 'Дистанция неизвестна'} · ${duration != null && duration >= 0 ? workoutTime(Duration(seconds: duration)) : 'Время неизвестно'}',
                        ),
                        Text(
                          '${shortDate(post.rideCreatedAt ?? post.createdAt)}.${(post.rideCreatedAt ?? post.createdAt).year}',
                        ),
                        if (post.audience == CommunityPostAudience.friends)
                          const Text('Только друзья'),
                      ],
                    ),
                    trailing: widget.onOpenPost == null
                        ? null
                        : const Icon(Icons.chevron_right),
                    onTap: widget.onOpenPost == null
                        ? null
                        : () => widget.onOpenPost!(post),
                  ),
                );
              }),
          ],
        ),
      ],
    );
  }
}
