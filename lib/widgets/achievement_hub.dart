import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/owner_award.dart';
import '../services/achievement_journey.dart';
import '../ui/app_theme.dart';

Color medalColor(MedalRarity rarity) => switch (rarity) {
  MedalRarity.bronze => const Color(0xFFAE7948),
  MedalRarity.silver => const Color(0xFF6B8291),
  MedalRarity.gold => const Color(0xFFB68A22),
  MedalRarity.epic => const Color(0xFF8660AB),
  MedalRarity.legendary => const Color(0xFFD56937),
};

class AchievementHub extends StatefulWidget {
  const AchievementHub({
    super.key,
    required this.journey,
    required this.onRefresh,
    required this.records,
    required this.statistics,
    this.catalogFailed = false,
    this.titles = const [],
    this.onEquipTitle,
  });
  final AchievementJourney journey;
  final Future<void> Function() onRefresh;
  final Widget records, statistics;
  final bool catalogFailed;
  final List<OwnerAward> titles;
  final Future<void> Function(OwnerAward)? onEquipTitle;
  @override
  State<AchievementHub> createState() => _AchievementHubState();
}

class _AchievementHubState extends State<AchievementHub> {
  String _tab = 'Все', _category = 'Все направления';
  String? _equipping;
  static const _pine = Color(0xFF183D34);
  @override
  Widget build(BuildContext context) {
    final j = widget.journey;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final earned = j.medals.where((m) => m.earned).length;
    final categories = [
      'Все направления',
      ...j.medals.map((m) => m.category).toSet(),
    ];
    final medals =
        j.medals
            .where(
              (m) =>
                  (_category == categories.first || m.category == _category) &&
                  (_tab == 'Все' ||
                      _tab == 'Получено' && m.earned ||
                      _tab == 'В процессе' && !m.earned),
            )
            .toList()
          ..sort(
            (a, b) => a.earned == b.earned
                ? b.progress.compareTo(a.progress)
                : a.earned
                ? 1
                : -1,
          );
    return Scaffold(
      backgroundColor: dark ? const Color(0xFF101D19) : const Color(0xFFF5F4EE),
      appBar: AppBar(
        title: const Text('Ваш путь'),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            onPressed: widget.onRefresh,
            tooltip: 'Обновить',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: widget.onRefresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
          children: [
            _hero(j, earned),
            const SizedBox(height: 12),
            const Text(
              'Медали дают XP и открывают титулы пути. Откройте медаль, чтобы увидеть условия и свой прогресс.',
            ),
            const SizedBox(height: 24),
            _weeklyGoals(j),
            const SizedBox(height: 24),
            if (j.rides.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  'Ваши достижения впереди! Сохраните первый заезд — и начните свою коллекцию.',
                ),
              ),
            if (j.nextGoals.isNotEmpty) ...[
              _heading(
                'Следующая победа',
                'Каждая тренировка приближает к цели',
              ),
              const SizedBox(height: 12),
              for (final medal in j.nextGoals.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _nextGoal(medal),
                ),
              const SizedBox(height: 24),
            ],
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final tab in ['Все', 'В процессе', 'Получено', 'Титулы'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(tab == 'Получено' ? '$tab · $earned' : tab),
                        selected: _tab == tab,
                        onSelected: (_) => setState(() => _tab = tab),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_tab == 'Титулы')
              _titles(j)
            else ...[
              DropdownButtonFormField<String>(
                initialValue: _category,
                isExpanded: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.explore_outlined),
                  border: OutlineInputBorder(),
                ),
                items: categories
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (c) =>
                    setState(() => _category = c ?? categories.first),
              ),
              const SizedBox(height: 16),
              if (medals.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Здесь появятся ваши награды. Выберите цель и двигайтесь в своём темпе.',
                    textAlign: TextAlign.center,
                  ),
                ),
              LayoutBuilder(
                builder: (context, constraints) => GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: constraints.maxWidth >= 650
                        ? 3
                        : constraints.maxWidth < 280
                        ? 1
                        : 2,
                    mainAxisExtent:
                        238 * MediaQuery.textScalerOf(context).scale(1),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                  itemCount: medals.length,
                  itemBuilder: (context, index) => _medal(medals[index]),
                ),
              ),
            ],
            const SizedBox(height: 24),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Личные рекорды'),
              subtitle: const Text('Лучшие результаты по видам активности'),
              children: [widget.records],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('В цифрах'),
              children: [widget.statistics],
            ),
            if (widget.catalogFailed)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text(
                  'Дополнительные награды не загрузились. Ваша локальная коллекция доступна; потяните вниз, чтобы повторить.',
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _heading(String title, String subtitle) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.w800,
          letterSpacing: -.5,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        subtitle,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
    ],
  );

  Widget _hero(AchievementJourney j, int earned) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(28),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_pine, Color(0xFF29584A), Color(0xFF14362F)],
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'КОЛЛЕКЦИЯ ВАШИХ ПОБЕД',
                    style: TextStyle(
                      color: Color(0xFFB9D4C5),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.6,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    j.rank.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      height: 1.12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    j.rank.description,
                    style: const TextStyle(
                      color: Color(0xFFCBDFD2),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 70,
              height: 78,
              child: CustomPaint(
                painter: const _MedallionPainter(Color(0xFFE4BD68), true),
                child: Center(
                  child: Text(
                    j.rank.icon,
                    style: const TextStyle(fontSize: 32),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 16,
          runSpacing: 8,
          children: [
            Text(
              '${j.xp} XP',
              style: const TextStyle(
                color: Color(0xFFF2D98F),
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              '$earned / ${j.medals.length} наград',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AppProgressIndicator(
            value: j.rankProgress,
            minHeight: 7,
            color: const Color(0xFFE4BD68),
            backgroundColor: Colors.white12,
          ),
        ),
        const SizedBox(height: 9),
        Text(
          j.nextRank == null
              ? 'Высший титул открыт. Путь продолжается.'
              : 'Ещё ${j.nextRank!.xp - j.xp} XP → ${j.nextRank!.name}',
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    ),
  );

  Widget _weeklyGoals(AchievementJourney journey) => Card(
    margin: EdgeInsets.zero,
    child: ExpansionTile(
      leading: const Icon(Icons.flag_outlined),
      title: const Text('Ваши цели недели'),
      subtitle: Text(
        '${journey.weeklyStart.day}.${journey.weeklyStart.month} — ${journey.weeklyEnd.day}.${journey.weeklyEnd.month} · ${journey.weeklyGoals.where((goal) => goal.completed).length} из ${journey.weeklyGoals.length} выполнено',
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Личные ориентиры, без соревнования. Прогресс считается с понедельника по воскресенье по сохранённым тренировкам. Каждую неделю — новый старт; XP дают медали.',
              ),
              for (final goal in journey.weeklyGoals) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(goal.icon, style: const TextStyle(fontSize: 24)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        goal.title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (goal.completed)
                      const Icon(Icons.check_circle, color: Colors.green),
                  ],
                ),
                const SizedBox(height: 4),
                Text(goal.description),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: goal.progress, minHeight: 6),
                const SizedBox(height: 4),
                Text(
                  goal.completed
                      ? 'Готово · ${goal.progressText}'
                      : goal.progressText,
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );

  Widget _nextGoal(JourneyMedal m) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: BorderSide(color: medalColor(m.rarity).withValues(alpha: .3)),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: () => _details(m),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Text(m.badge.icon, style: const TextStyle(fontSize: 32)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.badge.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: m.progress,
                    color: medalColor(m.rarity),
                    minHeight: 5,
                  ),
                  const SizedBox(height: 6),
                  Text(m.remainingText, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '+${m.rarity.xp}\nXP',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: medalColor(m.rarity),
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _medal(JourneyMedal m) {
    final color = medalColor(m.rarity);
    return Card(
      key: ValueKey(m.id),
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: color.withValues(alpha: m.earned ? .6 : .18)),
      ),
      child: InkWell(
        onTap: () => _details(m),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      m.rarity.label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color,
                        fontSize: 9,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Icon(
                    m.earned ? Icons.check_circle : Icons.lock_outline,
                    size: 15,
                    color: m.earned ? color : Colors.grey,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: 64,
                height: 70,
                child: CustomPaint(
                  painter: _MedallionPainter(color, m.earned),
                  child: Center(
                    child: Opacity(
                      opacity: m.earned ? 1 : .5,
                      child: Text(
                        m.badge.icon,
                        style: const TextStyle(fontSize: 28),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                m.badge.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              Text(
                m.category,
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: AppProgressIndicator(
                  value: m.progress,
                  color: color,
                  backgroundColor: color.withValues(alpha: .1),
                  minHeight: 4,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                m.progressText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _details(JourneyMedal m) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 100,
            height: 112,
            child: CustomPaint(
              painter: _MedallionPainter(medalColor(m.rarity), m.earned),
              child: Center(
                child: Text(m.badge.icon, style: const TextStyle(fontSize: 48)),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            m.badge.title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            '${m.rarity.label} · ${m.category} · +${m.rarity.xp} XP',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Text(
            m.story,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          const Text(
            'Условия достижения',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(m.badge.publicDescription, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          LinearProgressIndicator(
            value: m.progress,
            color: medalColor(m.rarity),
            minHeight: 7,
          ),
          const SizedBox(height: 10),
          Text(
            m.progressText,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(m.remainingText),
          const SizedBox(height: 20),
          const Text(
            'Двигайтесь в комфортном темпе. Награды начисляются за сохранённые тренировки.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
  );

  Widget _titles(AchievementJourney j) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _heading(
        'Титулы пути',
        '${JourneyRank.all.length} уровней · открываются за XP полученных медалей',
      ),
      const SizedBox(height: 16),
      for (final rank in JourneyRank.all)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: AnimatedContainer(
            key: ValueKey(rank.xp),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: rank == j.rank
                  ? _pine
                  : Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: rank == j.rank
                    ? const Color(0xFFE4BD68)
                    : Colors.grey.withValues(alpha: .2),
              ),
            ),
            child: Row(
              children: [
                Text(
                  rank.icon,
                  style: TextStyle(
                    fontSize: 30,
                    color: j.xp < rank.xp ? Colors.grey : null,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rank.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: rank == j.rank ? Colors.white : null,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        rank.description,
                        style: TextStyle(
                          fontSize: 11,
                          color: rank == j.rank ? Colors.white70 : null,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        rank == j.rank
                            ? 'ВАШ ТЕКУЩИЙ ТИТУЛ'
                            : j.xp >= rank.xp
                            ? 'ОТКРЫТ · ${rank.xp} XP'
                            : 'ЕЩЁ ${rank.xp - j.xp} XP',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: rank == j.rank
                              ? const Color(0xFFE4BD68)
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      if (widget.titles.isNotEmpty) ...[
        const SizedBox(height: 12),
        _heading('Особые титулы', 'Выданные вам персональные награды'),
        for (final title in widget.titles)
          Card(
            child: ListTile(
              leading: Text(title.icon, style: const TextStyle(fontSize: 26)),
              title: Text(title.label),
              subtitle: Text(
                title.equipped
                    ? 'Установлен в профиле'
                    : 'Можно установить под именем',
              ),
              trailing: _equipping == title.id
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      title.equipped
                          ? Icons.check_circle
                          : Icons.add_circle_outline,
                    ),
              onTap: _equipping != null || widget.onEquipTitle == null
                  ? null
                  : () async {
                      setState(() => _equipping = title.id);
                      try {
                        await widget.onEquipTitle!(title);
                      } catch (_) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Не удалось установить титул. Попробуйте ещё раз.',
                              ),
                            ),
                          );
                        }
                      } finally {
                        if (mounted) setState(() => _equipping = null);
                      }
                    },
            ),
          ),
      ],
    ],
  );
}

class _MedallionPainter extends CustomPainter {
  const _MedallionPainter(this.color, this.earned);
  final Color color;
  final bool earned;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    Path hex(double scale) {
      final path = Path();
      for (var i = 0; i < 6; i++) {
        final angle = math.pi / 3 * i - math.pi / 2;
        final point =
            center +
            Offset(
              math.cos(angle) * size.width * .48 * scale,
              math.sin(angle) * size.height * .48 * scale,
            );
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      return path..close();
    }

    canvas.drawPath(
      hex(1),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: earned ? .55 : .08),
            color.withValues(alpha: earned ? .15 : .03),
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      hex(1),
      Paint()
        ..color = color.withValues(alpha: earned ? .85 : .3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawPath(
      hex(.85),
      Paint()
        ..color = color.withValues(alpha: earned ? .4 : .1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _MedallionPainter old) =>
      old.color != color || old.earned != earned;
}
