import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/services/workout_reminder_clock.dart';

void main() {
  test('water reminders default to disabled', () {
    final clock = WorkoutReminderClock();
    expect(clock.consumeIfDue(const Duration(hours: 3)), isFalse);
  });

  test('only active elapsed time advances the reminder', () {
    final clock = WorkoutReminderClock()..configure(15, Duration.zero);
    expect(clock.consumeIfDue(const Duration(minutes: 14)), isFalse);
    // A pause repeatedly presents the same active elapsed time.
    expect(clock.consumeIfDue(const Duration(minutes: 14)), isFalse);
    expect(clock.consumeIfDue(const Duration(minutes: 15)), isTrue);
    expect(clock.consumeIfDue(const Duration(minutes: 15)), isFalse);
    expect(clock.consumeIfDue(const Duration(minutes: 30)), isTrue);
  });

  test('delayed background tick emits once and schedules from now', () {
    final clock = WorkoutReminderClock()..configure(10, Duration.zero);
    expect(clock.consumeIfDue(const Duration(minutes: 45)), isTrue);
    expect(clock.consumeIfDue(const Duration(minutes: 45)), isFalse);
    expect(clock.consumeIfDue(const Duration(minutes: 54)), isFalse);
    expect(clock.consumeIfDue(const Duration(minutes: 55)), isTrue);
  });

  test('new interval and restored workout do not replay old reminders', () {
    final clock = WorkoutReminderClock()
      ..configure(20, const Duration(minutes: 65));
    expect(clock.consumeIfDue(const Duration(minutes: 65)), isFalse);
    expect(clock.consumeIfDue(const Duration(minutes: 85)), isTrue);
    clock.configure(10, const Duration(minutes: 86));
    expect(clock.consumeIfDue(const Duration(minutes: 95)), isFalse);
    expect(clock.consumeIfDue(const Duration(minutes: 96)), isTrue);
  });

  test('disabling, invalid intervals and a new workout clear the deadline', () {
    final clock = WorkoutReminderClock()..configure(10, Duration.zero);
    clock.configure(0, const Duration(minutes: 9));
    expect(clock.consumeIfDue(const Duration(hours: 2)), isFalse);
    clock.configure(-10, Duration.zero);
    expect(clock.consumeIfDue(const Duration(hours: 2)), isFalse);
    clock.configure(10, Duration.zero);
    expect(clock.consumeIfDue(const Duration(minutes: 9)), isFalse);
    expect(clock.consumeIfDue(const Duration(minutes: 10)), isTrue);
  });
}
