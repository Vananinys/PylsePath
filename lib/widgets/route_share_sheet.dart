import 'package:flutter/material.dart';

import '../models/shared_route.dart';
import '../models/friend_profile.dart';
import '../data/workout_history_repository.dart';
import '../data/saved_routes_repository.dart';
import '../data/user_scope.dart';
import '../services/friend_service.dart';
import '../services/chat_service.dart';
import '../models/saved_route.dart';
import '../services/ride_media_service.dart';
import 'ride_media_selection.dart';
import 'track_privacy_picker.dart';

Future<void> showRouteShareSheet(
  BuildContext context,
  SharedRoute route, {
  SavedRoute? source,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _ShareSheet(route: route, source: source),
);

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.route, this.source});
  final SharedRoute route;
  final SavedRoute? source;
  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final _owner = ChatService().userId;
  late final _friends = FriendService().fetchFriends();
  String? _sending;
  bool _includeTrack = true;
  int _radius = 0;
  Set<String> _mediaIds = {};
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .65,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Отправить в чат',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
          if (widget.source != null)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .27,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    children: [
                      TrackPrivacyPicker(
                        route: widget.source!,
                        enabled: _includeTrack,
                        radius: _radius,
                        onEnabled: (value) {
                          if (_sending == null) {
                            setState(() => _includeTrack = value);
                          }
                        },
                        onRadius: (value) {
                          if (_sending == null) setState(() => _radius = value);
                        },
                      ),
                      RideMediaSelection(
                        rideId: widget.source!.localId,
                        enabled: _includeTrack,
                        busy: _sending != null,
                        onChanged: (ids) => _mediaIds = ids,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Друг получит карточку со статистикой и доступным треком.',
            ),
          ),
          Expanded(
            child: FutureBuilder<List<FriendProfile>>(
              future: _friends,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.data!.isEmpty) {
                  return const Center(
                    child: Text('Сначала добавьте друга в сообществе'),
                  );
                }
                return ListView(
                  children: [
                    for (final friend in snapshot.data!)
                      ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.person_outline),
                        ),
                        title: Text(friend.username),
                        trailing: _sending == friend.id
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(),
                              )
                            : const Icon(Icons.send),
                        enabled: _sending == null,
                        onTap: () async {
                          setState(() => _sending = friend.id);
                          try {
                            final owner = _owner;
                            if (owner == null ||
                                owner != ChatService().userId) {
                              throw StateError(
                                'Аккаунт изменился. Откройте отправку заново.',
                              );
                            }
                            final snapshot = widget.source == null
                                ? widget.route
                                : await RideMediaService.prepareShare(
                                    widget.source!,
                                    selectedIds: _includeTrack ? _mediaIds : {},
                                    includeTrack: _includeTrack,
                                    hideRadiusMeters: _radius.toDouble(),
                                    kind: widget.route.kind,
                                  );
                            if (!mounted || owner != ChatService().userId) {
                              return;
                            }
                            await ChatService().sendMessage(
                              friend.id,
                              text:
                                  '${widget.route.label}: ${widget.route.title}',
                              routeAttachment: snapshot,
                            );
                            if (!context.mounted) return;
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Карточка отправлена в чат'),
                              ),
                            );
                          } catch (_) {
                            if (mounted) {
                              setState(() => _sending = null);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Не удалось отправить. Повторите.',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

Future<SharedRoute?> showLocalRoutePicker(BuildContext context) async {
  final owner = UserScope.currentUserId();
  final history = WorkoutHistoryRepository(), saved = SavedRoutesRepository();
  try {
    await Future.wait([history.load(), saved.load()]);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось прочитать поездки и маршруты'),
        ),
      );
    }
    return null;
  }
  if (!context.mounted || owner != UserScope.currentUserId()) return null;
  return showModalBottomSheet<SharedRoute>(
    context: context,
    isScrollControlled: true,
    builder: (_) => LocalRoutePicker(
      owner: owner,
      routes: List.of(saved.savedRoutes.reversed),
      workouts: List.of(history.workoutHistory.reversed),
    ),
  );
}

class LocalRoutePicker extends StatefulWidget {
  const LocalRoutePicker({
    required this.routes,
    required this.workouts,
    required this.owner,
  });
  final List<SavedRoute> routes, workouts;
  final String? owner;
  @override
  State<LocalRoutePicker> createState() => LocalRoutePickerState();
}

@visibleForTesting
bool matchesLocalRouteFilters(
  SavedRoute route, {
  DateTimeRange? dates,
  double? minDistance,
  double? maxDistance,
  double? minMinutes,
  double? maxMinutes,
}) {
  final date = route.recordedDateTime?.toLocal();
  if (dates != null &&
      (date == null ||
          date.isBefore(dates.start) ||
          !date.isBefore(
            DateTime(dates.end.year, dates.end.month, dates.end.day + 1),
          ))) {
    return false;
  }
  if ((minDistance != null || maxDistance != null) &&
      route.distanceMeters == null &&
      route.distance.trim().isEmpty)
    return false;
  if ((minMinutes != null || maxMinutes != null) &&
      route.durationSeconds == null &&
      route.duration.trim().isEmpty)
    return false;
  if (minDistance != null && route.distanceKm < minDistance) return false;
  if (maxDistance != null && route.distanceKm > maxDistance) return false;
  if (minMinutes != null && route.durationMin < minMinutes) return false;
  if (maxMinutes != null && route.durationMin > maxMinutes) return false;
  return true;
}

class LocalRoutePickerState extends State<LocalRoutePicker> {
  var _routes = true;
  DateTimeRange? _dates;
  double? _minDistance, _maxDistance, _minMinutes, _maxMinutes;
  final minKm = TextEditingController();
  final maxKm = TextEditingController();
  final minTime = TextEditingController();
  final maxTime = TextEditingController();

  @override
  void dispose() {
    minKm.dispose();
    maxKm.dispose();
    minTime.dispose();
    maxTime.dispose();
    super.dispose();
  }

  bool get _hasFilters =>
      _dates != null ||
      _minDistance != null ||
      _maxDistance != null ||
      _minMinutes != null ||
      _maxMinutes != null;

  bool _matches(SavedRoute route) => matchesLocalRouteFilters(
    route,
    dates: _dates,
    minDistance: _minDistance,
    maxDistance: _maxDistance,
    minMinutes: _minMinutes,
    maxMinutes: _maxMinutes,
  );

  Future<void> _filter() async {
    minKm.text = _minDistance?.toString() ?? '';
    maxKm.text = _maxDistance?.toString() ?? '';
    minTime.text = _minMinutes?.toString() ?? '';
    maxTime.text = _maxMinutes?.toString() ?? '';
    DateTimeRange? dates = _dates;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          Widget number(String label, TextEditingController controller) =>
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(labelText: label),
              );
          return AlertDialog(
            title: const Text('Фильтры'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Период'),
                    subtitle: Text(
                      dates == null
                          ? 'Любая дата'
                          : '${MaterialLocalizations.of(context).formatShortDate(dates!.start)} — ${MaterialLocalizations.of(context).formatShortDate(dates!.end)}',
                    ),
                    trailing: const Icon(Icons.date_range),
                    onTap: () async {
                      final now = DateTime.now();
                      final result = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(now.year + 2),
                        initialDateRange: dates,
                      );
                      if (result != null) update(() => dates = result);
                    },
                  ),
                  if (dates != null)
                    TextButton(
                      onPressed: () => update(() => dates = null),
                      child: const Text('Любая дата'),
                    ),
                  number('Расстояние от, км', minKm),
                  number('Расстояние до, км', maxKm),
                  number('Длительность от, мин', minTime),
                  number('Длительность до, мин', maxTime),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  minKm.clear();
                  maxKm.clear();
                  minTime.clear();
                  maxTime.clear();
                  update(() {
                    dates = null;
                    error = null;
                  });
                },
                child: const Text('Сбросить'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () {
                  final fields = [minKm, maxKm, minTime, maxTime];
                  final values = fields
                      .map(
                        (field) => double.tryParse(
                          field.text.trim().replaceAll(',', '.'),
                        ),
                      )
                      .toList();
                  if (fields.asMap().entries.any(
                        (entry) =>
                            entry.value.text.trim().isNotEmpty &&
                            (values[entry.key] == null ||
                                !values[entry.key]!.isFinite ||
                                values[entry.key]! < 0),
                      ) ||
                      (values[0] != null &&
                          values[1] != null &&
                          values[0]! > values[1]!) ||
                      (values[2] != null &&
                          values[3] != null &&
                          values[2]! > values[3]!)) {
                    update(
                      () => error = 'Введите положительные значения: минимум не должен превышать максимум.',
                    );
                    return;
                  }
                  setState(() {
                    _dates = dates;
                    _minDistance = values[0];
                    _maxDistance = values[1];
                    _minMinutes = values[2];
                    _maxMinutes = values[3];
                  });
                  Navigator.pop(dialog);
                },
                child: const Text('Применить'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = (_routes ? widget.routes : widget.workouts)
        .where(_matches)
        .toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .78,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Выберите маршрут или тренировку',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: _filter,
                    tooltip: 'Фильтры',
                    icon: Badge(
                      isLabelVisible: _hasFilters,
                      child: const Icon(Icons.filter_list),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: const Text('Мои маршруты'),
                    selected: _routes,
                    onSelected: (_) => setState(() => _routes = true),
                  ),
                  ChoiceChip(
                    label: const Text('Мои тренировки'),
                    selected: !_routes,
                    onSelected: (_) => setState(() => _routes = false),
                  ),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Text(
                        _hasFilters
                            ? 'Нет подходящих записей'
                            : (_routes
                                  ? 'Нет сохранённых маршрутов'
                                  : 'Нет сохранённых тренировок'),
                      ),
                    )
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final route = items[index];
                        final date = route.recordedDateTime;
                        return ListTile(
                          leading: Icon(
                            _routes ? Icons.route : Icons.directions_run,
                          ),
                          title: Text(route.title),
                          subtitle: Text(
                            '${date == null ? 'Дата неизвестна' : MaterialLocalizations.of(context).formatShortDate(date.toLocal())} · ${route.distanceKm.toStringAsFixed(1)} км · ${route.displayDuration}',
                          ),
                          onTap: () {
                            if (widget.owner != UserScope.currentUserId()) {
                              Navigator.pop(context);
                              return;
                            }
                            Navigator.pop(
                              context,
                              SharedRoute.fromSavedRoute(
                                route,
                                kind: _routes ? 'route' : 'ride',
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
