/// Uses active workout time, so pauses and background wakeups cannot create
/// a burst of overdue reminders. No timer or platform alarms are allocated.
class WorkoutReminderClock {
  static const intervals = [0, 10, 15, 20, 30, 45, 60];
  int _intervalSeconds = 0;
  int _nextSeconds = 0;

  void configure(int minutes, Duration elapsed) {
    _intervalSeconds = intervals.contains(minutes) ? minutes * 60 : 0;
    _nextSeconds = elapsed.inSeconds + _intervalSeconds;
  }

  bool consumeIfDue(Duration elapsed) {
    if (_intervalSeconds == 0 || elapsed.inSeconds < _nextSeconds) return false;
    _nextSeconds = elapsed.inSeconds + _intervalSeconds;
    return true;
  }
}
