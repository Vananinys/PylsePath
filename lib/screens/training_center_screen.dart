import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';

import '../data/progress_goals_repository.dart';
import '../data/user_scope.dart';
import '../data/workout_history_repository.dart';
import '../models/progress_period.dart';
import '../models/saved_route.dart';
import '../models/workout_details.dart';
import '../models/workout_record.dart';
import '../services/training_insights.dart';
import 'workout_detail_screen.dart';
import 'workout_history_screen.dart';

enum _TrendMetric { distance, time, climb, load }

class TrainingCenterScreen extends StatefulWidget {
  const TrainingCenterScreen({super.key});
  @override
  State<TrainingCenterScreen> createState() => _TrainingCenterScreenState();
}

class _TrainingCenterScreenState extends State<TrainingCenterScreen> {
  final _repo = WorkoutHistoryRepository();
  final _goals = ProgressGoalsRepository();
  final _owner = UserScope.currentUserId();
  List<SavedRoute> _history = [];
  TrainingSport _sport = TrainingSport.all;
  _TrendMetric _metric = _TrendMetric.distance;
  DateTime _selectedDay = trainingDay(DateTime.now());
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await Future.wait([_repo.load(), _goals.load(syncCloud: false)]);
      if (!mounted || UserScope.currentUserId() != _owner) return;
      setState(() {
        _history = _repo.workoutHistory;
        _loading = false;
        _error = null;
      });
      unawaited(_syncGoals());
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Не удалось прочитать тренировки. Повторите загрузку.';
        });
      }
    }
  }

  Future<void> _syncGoals() async {
    await _goals.load();
    if (mounted && UserScope.currentUserId() == _owner) setState(() {});
  }

  void _open(SavedRoute ride) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) =>
          WorkoutDetailScreen(workout: WorkoutRecord.fromSavedRoute(ride)),
    ),
  ).then((_) => _load());

  @override
  Widget build(BuildContext context) {
    final insights = TrainingInsights(_history, sport: _sport);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Тренировочный центр'),
        actions: [
          IconButton(
            tooltip: 'История и синхронизация',
            icon: const Icon(Icons.history),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const WorkoutHistoryScreen()),
              );
              await _load();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (_error != null)
                    Card(
                      child: ListTile(
                        title: Text(_error!),
                        trailing: IconButton(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                        ),
                      ),
                    ),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final sport in TrainingSport.values)
                        ChoiceChip(
                          label: Text(sport.label),
                          selected: _sport == sport,
                          onSelected: (_) => setState(() => _sport = sport),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _weekOverview(insights),
                  const SizedBox(height: 16),
                  _weeklyGoal(),
                  const SizedBox(height: 16),
                  _trends(insights),
                  const SizedBox(height: 16),
                  _calendar(insights),
                  const SizedBox(height: 12),
                  Text(
                    'Занятия · ${_date(_selectedDay)}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (insights.onDay(_selectedDay).isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Text('В этот день сохранённых занятий нет.'),
                    ),
                  for (final ride in insights.onDay(_selectedDay))
                    _rideTile(ride),
                  const SizedBox(height: 16),
                  _milestones(insights),
                  const SizedBox(height: 20),
                ],
              ),
            ),
    );
  }

  Widget _weekOverview(TrainingInsights insights) {
    final total = insights.thisWeek, before = insights.previousWeekToDate;
    final change = total.km - before.km;
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Эта неделя · ${_sport.label.toLowerCase()}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          Text(
            '${total.km.toStringAsFixed(1)} км',
            style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w800),
          ),
          Text(
            '${change >= 0 ? '+' : '−'}${change.abs().toStringAsFixed(1)} км к тем же дням прошлой недели',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              _stat('Движение', workoutTime(Duration(seconds: total.seconds))),
              _stat('Набор', '${total.climb.round()} м'),
              _stat('Занятия', '${total.count}'),
              _stat('Активные дни', '${total.activeDays} / 7'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        value,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
      ),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );

  Widget _weeklyGoal() {
    final km = TrainingInsights(_history).thisWeek.km;
    final goal = _goals.goalFor(ProgressPeriod.week);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.flag_outlined, color: Colors.deepOrange),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Цель недели · все виды',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  tooltip: 'Изменить цель недели',
                  onPressed: _editGoal,
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
            Text('${km.toStringAsFixed(1)} из ${goal.toStringAsFixed(0)} км'),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: (km / goal).clamp(0, 1),
              minHeight: 8,
              borderRadius: BorderRadius.circular(8),
            ),
            const SizedBox(height: 8),
            Text(
              km >= goal
                  ? 'Цель выполнена'
                  : 'Осталось ${(goal - km).toStringAsFixed(1)} км',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editGoal() async {
    final value = await showDialog<double>(
      context: context,
      builder: (_) => _WeeklyGoalDialog(_goals.goalFor(ProgressPeriod.week)),
    );
    if (value == null || !mounted || UserScope.currentUserId() != _owner) {
      return;
    }
    try {
      final saving = _goals.setGoal(ProgressPeriod.week, value);
      setState(() {});
      await saving;
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось сохранить цель. Повторите попытку.'),
          ),
        );
      }
    }
  }

  double _value(TrainingTotals t) => switch (_metric) {
    _TrendMetric.distance => t.km,
    _TrendMetric.time => t.seconds / 3600,
    _TrendMetric.climb => t.climb,
    _TrendMetric.load => t.effortLoad,
  };

  Widget _trends(TrainingInsights insights) {
    final weeks = insights.weeks;
    final max = weeks.fold<double>(1, (v, w) => math.max(v, _value(w.totals)));
    const names = ['Километры', 'Часы', 'Набор, м', 'Нагрузка'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Ритм за 8 недель',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              children: [
                for (final metric in _TrendMetric.values)
                  ChoiceChip(
                    label: Text(names[metric.index]),
                    selected: _metric == metric,
                    onSelected: (_) => setState(() => _metric = metric),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 160,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final week in weeks)
                    Expanded(
                      child: Semantics(
                        label:
                            'Неделя ${_date(week.start)}: ${_value(week.totals).toStringAsFixed(1)} ${names[_metric.index]}',
                        child: InkWell(
                          onTap: () => setState(() {
                            _month = DateTime(
                              week.start.year,
                              week.start.month,
                            );
                            _selectedDay = week.start;
                          }),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                FittedBox(
                                  child: Text(
                                    _value(week.totals).toStringAsFixed(
                                      _metric == _TrendMetric.time ? 1 : 0,
                                    ),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  height: 105 * _value(week.totals) / max + 2,
                                  decoration: BoxDecoration(
                                    color: week == weeks.last
                                        ? Colors.deepOrange
                                        : Colors.deepOrange.withValues(
                                            alpha: .35,
                                          ),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                FittedBox(
                                  child: Text(
                                    '${week.start.day}.${week.start.month}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_metric == _TrendMetric.load) ...[
              const SizedBox(height: 10),
              const Text(
                'Нагрузка = минуты движения × усилие 1–10. Учитываются только занятия с указанным усилием; это дневник ощущений.',
              ),
              Text(
                'На этой неделе оценено ${insights.thisWeek.effortCount} из ${insights.thisWeek.count} занятий.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _calendar(TrainingInsights insights) {
    final first = DateTime(_month.year, _month.month);
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final offset = first.weekday - 1;
    final cells = ((offset + days) / 7).ceil() * 7;
    final now = DateTime.now();
    final canNext = _month.isBefore(DateTime(now.year, now.month));
    final byDay = <DateTime, TrainingTotals>{};
    for (var n = 1; n <= days; n++) {
      final date = DateTime(_month.year, _month.month, n);
      byDay[date] = TrainingTotals.of(insights.onDay(date));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Предыдущий месяц',
                  onPressed: () => _changeMonth(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    '${const ['Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь'][_month.month - 1]} ${_month.year}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  tooltip: 'Следующий месяц',
                  onPressed: canNext ? () => _changeMonth(1) : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            Row(
              children: [
                for (final day in ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'])
                  Expanded(
                    child: Center(
                      child: Text(
                        day,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                childAspectRatio: .85,
              ),
              itemCount: cells,
              itemBuilder: (context, index) {
                final day = index - offset + 1;
                if (day < 1 || day > days) return const SizedBox.shrink();
                final date = DateTime(_month.year, _month.month, day);
                final total = byDay[date]!;
                final selected = date == _selectedDay;
                return Semantics(
                  button: true,
                  selected: selected,
                  label: '${_date(date)}, занятий: ${total.count}',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => _selectedDay = date),
                    child: Container(
                      margin: const EdgeInsets.all(1),
                      decoration: BoxDecoration(
                        color: selected
                            ? Colors.deepOrange.withValues(alpha: .15)
                            : null,
                        border: selected
                            ? Border.all(color: Colors.deepOrange)
                            : null,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '$day',
                            style: TextStyle(
                              fontWeight: selected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          const SizedBox(height: 3),
                          if (total.count > 0)
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.deepOrange,
                                shape: BoxShape.circle,
                              ),
                            )
                          else
                            const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 4),
            const Text(
              'Точка — день с сохранённым занятием',
              style: TextStyle(fontSize: 12),
            ),
            TextButton(
              onPressed: () => setState(() {
                _month = DateTime(now.year, now.month);
                _selectedDay = trainingDay(now);
              }),
              child: const Text('Сегодня'),
            ),
          ],
        ),
      ),
    );
  }

  void _changeMonth(int delta) => setState(() {
    _month = DateTime(_month.year, _month.month + delta);
    _selectedDay = _month;
  });

  Widget _rideTile(SavedRoute ride) => Card(
    child: ListTile(
      leading: Icon(ride.activityType.icon, color: Colors.deepOrange),
      title: Text(ride.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${ride.activityType.label} · ${ride.distanceKm.toStringAsFixed(1)} км · ${ride.displayDuration}'
        '${ride.workoutDetails.effort == null ? '' : ' · усилие ${ride.workoutDetails.effort}/10'}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _open(ride),
    ),
  );

  Widget _milestones(TrainingInsights insights) {
    final rides =
        insights.rides.where((r) => !r.dateTime.isAfter(insights.now)).toList()
          ..sort((a, b) => b.distanceKm.compareTo(a.distanceKm));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Личные ориентиры',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('Недель подряд с занятиями: ${insights.consecutiveWeeks}'),
            const SizedBox(height: 4),
            if (rides.isNotEmpty)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.route, color: Colors.deepOrange),
                title: Text(
                  'Самая длинная · ${rides.first.distanceKm.toStringAsFixed(1)} км',
                ),
                subtitle: Text(
                  '${_date(rides.first.dateTime)} · ${rides.first.activityType.label}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(rides.first),
              )
            else
              const Text(
                'Запишите занятие — здесь появятся ваши личные ориентиры.',
              ),
            const Text(
              'По сохранённой истории выбранных видов занятий.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  String _date(DateTime value) {
    final d = value.toLocal();
    return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
  }
}

class _WeeklyGoalDialog extends StatefulWidget {
  const _WeeklyGoalDialog(this.goal);
  final double goal;
  @override
  State<_WeeklyGoalDialog> createState() => _WeeklyGoalDialogState();
}

class _WeeklyGoalDialogState extends State<_WeeklyGoalDialog> {
  late final _input = TextEditingController(
    text: widget.goal.round().toString(),
  );
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Дистанция за неделю'),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _input,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'От 10 до 5000 км'),
        validator: (v) {
          final n = double.tryParse((v ?? '').replaceAll(',', '.'));
          return n == null || !n.isFinite || n < 10 || n > 5000
              ? 'Введите от 10 до 5000 км'
              : null;
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(
              context,
              double.parse(_input.text.replaceAll(',', '.')),
            );
          }
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
}
