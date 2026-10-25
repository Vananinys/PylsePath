import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/services/presence_service.dart';
import 'package:pulsepath/models/friend_profile.dart';

void main() {
  final now = DateTime.utc(2026, 10, 17, 12);
  test('Online status expires after a lost connection and respects background state', () {
    final present = UserPresence(true, now);
    expect(present.textAt(now), 'В сети');
    expect(present.isOnlineAt(now.add(const Duration(seconds: 70))), isFalse);
    expect(UserPresence(false, now).textAt(now), 'Был(а) только что');
    expect(const UserPresence(false, null).textAt(now), 'Не в сети');
  });
  test(
    'Typing and voice recording expire without receiving an explicit stop',
    () {
      expect(ChatActivity('typing', now).textAt(now), 'Печатает…');
      expect(
        ChatActivity('recording', now).textAt(now),
        'Записывает голосовое…',
      );
      expect(
        ChatActivity(
          'recording',
          now,
        ).textAt(now.add(const Duration(seconds: 8))),
        isNull,
      );
      expect(ChatActivity('idle', now).textAt(now), isNull);
    },
  );
  test(
    'Being at home with a fresh location does not imply an active workout',
    () {
      final home = FriendProfile(
        id: 'friend',
        username: 'Друг',
        liveLatitude: 56,
        liveLongitude: 85,
        liveUpdatedAt: DateTime.now(),
        liveActivity: 'idle',
      );
      expect(home.hasLivePosition, isTrue);
      expect(home.isLive, isFalse);
      expect(home.motionText, 'Позиция обновляется');
    },
  );
}
