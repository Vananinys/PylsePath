class IntervalPhase {
  const IntervalPhase(this.label, this.start, this.seconds, {this.repeat});
  final String label;
  final int start, seconds;
  final int? repeat;
  int remaining(int activeSeconds) =>
      (start + seconds - activeSeconds).clamp(0, seconds);
  double progress(int activeSeconds) =>
      ((activeSeconds - start) / seconds).clamp(0, 1);
}

/// A time based session, independent of GPS and of the wall clock.
class IntervalPlan {
  const IntervalPlan({
    required this.warmup,
    required this.work,
    required this.recovery,
    required this.repeats,
    required this.cooldown,
  });
  final int warmup, work, recovery, repeats, cooldown;
  int get totalSeconds =>
      warmup + work * repeats + recovery * (repeats - 1) + cooldown;
  bool get isValid =>
      warmup >= 0 &&
      warmup <= 3600 &&
      work >= 10 &&
      work <= 3600 &&
      recovery >= 10 &&
      recovery <= 3600 &&
      repeats >= 1 &&
      repeats <= 30 &&
      cooldown >= 0 &&
      cooldown <= 3600;
  List<IntervalPhase> get phases {
    final result = <IntervalPhase>[];
    var start = 0;
    void add(String label, int seconds, [int? repeat]) {
      if (seconds <= 0) return;
      result.add(IntervalPhase(label, start, seconds, repeat: repeat));
      start += seconds;
    }

    add('Разминка', warmup);
    for (var i = 1; i <= repeats; i++) {
      add('Рабочий интервал', work, i);
      if (i < repeats) add('Восстановление', recovery, i);
    }
    add('Заминка', cooldown);
    return result;
  }

  IntervalPhase? phaseAt(int activeSeconds) {
    if (!isValid || activeSeconds < 0) return null;
    for (final phase in phases) {
      if (activeSeconds < phase.start + phase.seconds) return phase;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'warmup': warmup,
    'work': work,
    'recovery': recovery,
    'repeats': repeats,
    'cooldown': cooldown,
  };
  static IntervalPlan? fromJson(dynamic raw) {
    if (raw is! Map ||
        [
          'warmup',
          'work',
          'recovery',
          'repeats',
          'cooldown',
        ].any((k) => raw[k] is! int)) {
      return null;
    }
    final plan = IntervalPlan(
      warmup: raw['warmup'],
      work: raw['work'],
      recovery: raw['recovery'],
      repeats: raw['repeats'],
      cooldown: raw['cooldown'],
    );
    return plan.isValid ? plan : null;
  }
}
