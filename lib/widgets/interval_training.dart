import 'package:flutter/material.dart';

import '../controllers/map_navigation_controller.dart';
import '../models/interval_plan.dart';
import '../models/workout_details.dart';

class IntervalSetup extends StatelessWidget {
  const IntervalSetup({super.key, required this.controller});
  final MapNavigationController controller;
  @override
  Widget build(BuildContext context) {
    final plan = controller.intervalPlan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.timer_outlined, color: Colors.deepOrange),
          title: const Text('Интервальная тренировка'),
          subtitle: Text(
            plan == null
                ? 'Разминка, рабочие отрезки и восстановление'
                : '${plan.repeats} × ${workoutTime(Duration(seconds: plan.work))} · всего ${workoutTime(Duration(seconds: plan.totalSeconds))}',
          ),
          trailing: const Icon(Icons.tune),
          onTap: () async {
            final selected = await showDialog<IntervalPlan>(
              context: context,
              builder: (_) => _IntervalDialog(plan),
            );
            if (selected != null) controller.setIntervalPlan(selected);
          },
        ),
        if (plan != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => controller.setIntervalPlan(null),
              child: const Text('Убрать интервалы'),
            ),
          ),
      ],
    );
  }
}

class IntervalProgressCard extends StatelessWidget {
  const IntervalProgressCard({
    super.key,
    required this.plan,
    required this.activeSeconds,
    this.paused = false,
  });
  final IntervalPlan plan;
  final int activeSeconds;
  final bool paused;
  @override
  Widget build(BuildContext context) {
    final phase = plan.phaseAt(activeSeconds);
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer
          .withValues(alpha: .4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              phase == null
                  ? 'Интервальный план выполнен'
                  : '${phase.label}${phase.repeat == null ? '' : ' · ${phase.repeat}/${plan.repeats}'}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (phase != null) ...[
              Text(
                '${paused ? 'Пауза · осталось' : 'Осталось'} ${workoutTime(Duration(seconds: phase.remaining(activeSeconds)))}',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: phase.progress(activeSeconds)),
            ] else
              const Text(
                'Запись продолжается. Завершите занятие, когда будете готовы.',
              ),
            const SizedBox(height: 6),
            Text(
              'План: ${workoutTime(Duration(seconds: activeSeconds.clamp(0, plan.totalSeconds)))} / ${workoutTime(Duration(seconds: plan.totalSeconds))}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _IntervalDialog extends StatefulWidget {
  const _IntervalDialog(this.plan);
  final IntervalPlan? plan;
  @override
  State<_IntervalDialog> createState() => _IntervalDialogState();
}

class _IntervalDialogState extends State<_IntervalDialog> {
  final _form = GlobalKey<FormState>();
  late final _warmup = TextEditingController(
    text: _minutes(widget.plan?.warmup ?? 300),
  );
  late final _work = TextEditingController(
    text: _minutes(widget.plan?.work ?? 180),
  );
  late final _rest = TextEditingController(
    text: _minutes(widget.plan?.recovery ?? 120),
  );
  late final _cool = TextEditingController(
    text: _minutes(widget.plan?.cooldown ?? 300),
  );
  late final _repeats = TextEditingController(
    text: '${widget.plan?.repeats ?? 5}',
  );
  String _minutes(int seconds) => seconds % 60 == 0
      ? '${seconds ~/ 60}'
      : (seconds / 60).toStringAsFixed(2);
  int _seconds(TextEditingController c) =>
      (double.parse(c.text.replaceAll(',', '.')) * 60).round();
  @override
  void dispose() {
    for (final c in [_warmup, _work, _rest, _cool, _repeats]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _duration(
    TextEditingController controller,
    String label, {
    bool zero = false,
  }) => TextFormField(
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: '$label, мин'),
    validator: (v) {
      final n = double.tryParse((v ?? '').replaceAll(',', '.'));
      return n == null || !n.isFinite || n < (zero ? 0 : 1 / 6) || n > 60
          ? (zero ? 'От 0 до 60 минут' : 'От 10 секунд до 60 минут')
          : null;
    },
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('План интервалов'),
    content: SingleChildScrollView(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _duration(_warmup, 'Разминка', zero: true),
            _duration(_work, 'Рабочий интервал'),
            _duration(_rest, 'Восстановление между повторами'),
            TextFormField(
              controller: _repeats,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Повторы'),
              validator: (v) {
                final n = int.tryParse(v ?? '');
                return n == null || n < 1 || n > 30
                    ? 'От 1 до 30 повторов'
                    : null;
              },
            ),
            _duration(_cool, 'Заминка', zero: true),
            const SizedBox(height: 12),
            const Text(
              'Пауза останавливает план. После плана запись продолжается до ручного финиша.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          Navigator.pop(
            context,
            IntervalPlan(
              warmup: _seconds(_warmup),
              work: _seconds(_work),
              recovery: _seconds(_rest),
              repeats: int.parse(_repeats.text),
              cooldown: _seconds(_cool),
            ),
          );
        },
        child: const Text('Применить'),
      ),
    ],
  );
}
