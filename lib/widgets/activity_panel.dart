import 'package:flutter/material.dart';

import '../services/activity_service.dart';

class ActivityPanel extends StatelessWidget {
  const ActivityPanel({
    super.key,
    required this.summary,
    this.showAllTime = true,
    this.isOwner = false,
  });
  final ActivitySummary summary;
  final bool showAllTime, isOwner;
  @override
  Widget build(BuildContext context) {
    final s = summary;
    if (!s.visible && !isOwner) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('Пользователь скрыл статистику активности'),
        ),
      );
    }
    final lit = s.streak > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              colors: lit
                  ? [const Color(0xFF9A431C), const Color(0xFFDA722F)]
                  : [const Color(0xFF394D49), const Color(0xFF637971)],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.local_fire_department_rounded,
                    size: 48,
                    color: lit ? const Color(0xFFFFD784) : Colors.white54,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${s.streak} ${_days(s.streak)} подряд',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          s.activeToday
                              ? 'Огонёк продлён на сегодня'
                              : lit
                              ? 'Сегодня ещё можно продлить серию'
                              : 'Зажгите свой огонёк',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                isOwner
                    ? '10 минут или 1 км активности за день. Сохраните тренировку, чтобы продлить серию.'
                    : 'Серия сохранённых тренировок: от 10 минут или 1 км за день.',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: s.dayProgress,
                  minHeight: 6,
                  color: const Color(0xFFFFD784),
                  backgroundColor: Colors.white24,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: List.generate(7, (i) {
                  final date = DateTime(
                    s.day.year,
                    s.day.month,
                    s.day.day,
                  ).subtract(Duration(days: 6 - i));
                  final active = i < s.week.length && s.week[i];
                  return Expanded(
                    child: Column(
                      children: [
                        Icon(
                          active
                              ? Icons.local_fire_department
                              : Icons.circle_outlined,
                          color: active
                              ? const Color(0xFFFFD784)
                              : Colors.white38,
                          size: 23,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          const [
                            'Пн',
                            'Вт',
                            'Ср',
                            'Чт',
                            'Пт',
                            'Сб',
                            'Вс',
                          ][date.weekday - 1],
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ),
              const SizedBox(height: 14),
              Text(
                'Лучшая серия: ${s.best} ${_days(s.best)} · Активных дней: ${s.activeDays}',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Активность за день · ${s.day.day}.${s.day.month.toString().padLeft(2, '0')}',
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        ActivityStatsGrid(totals: s.today),
        if (showAllTime) ...[
          const SizedBox(height: 20),
          const Text(
            'Активность за всё время',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          ActivityStatsGrid(totals: s.total),
        ],
      ],
    );
  }

  static String _days(int n) => n % 100 >= 11 && n % 100 <= 14
      ? 'дней'
      : n % 10 == 1
      ? 'день'
      : n % 10 >= 2 && n % 10 <= 4
      ? 'дня'
      : 'дней';
}

class ActivityStatsGrid extends StatelessWidget {
  const ActivityStatsGrid({super.key, required this.totals});
  final ActivityTotals totals;
  @override
  Widget build(BuildContext context) {
    final values = [
      (Icons.route, '${totals.km.toStringAsFixed(1)} км', 'Дистанция'),
      (Icons.timer_outlined, totals.duration, 'Время движения'),
      (Icons.flag_outlined, '${totals.rides}', 'Тренировок'),
      (Icons.landscape_outlined, '${totals.climb.round()} м', 'Набор высоты'),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount:
              constraints.maxWidth < 260 ||
                  constraints.maxWidth < 480 &&
                      MediaQuery.textScalerOf(context).scale(1) > 1.25
              ? 1
              : 2,
          mainAxisExtent: 120 * MediaQuery.textScalerOf(context).scale(1),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        itemCount: values.length,
        itemBuilder: (context, i) => Card(
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  values[i].$1,
                  color: Theme.of(context).colorScheme.primary,
                  size: 25,
                ),
                const SizedBox(height: 7),
                Text(
                  values[i].$2,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  values[i].$3,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
