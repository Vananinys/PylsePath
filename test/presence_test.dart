import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/services/presence_service.dart';
import 'package:pulsepath/models/friend_profile.dart';

void main() {
  final now = DateTime.utc(2026, 10, 17, 12);
  test('Presence updates are scheduled at visible label boundaries', () {
    expect(const UserPresence(false, null).nextChangeAt(now), isNull);
    expect(
      UserPresence(true, now).nextChangeAt(now),
      now.add(const Duration(seconds: 70)),
    );
    expect(
      UserPresence(false, now).nextChangeAt(now),
      now.add(const Duration(minutes: 1)),
    );
    expect(
      UserPresence(
        false,
        now,
      ).nextChangeAt(now.add(const Duration(minutes: 12, seconds: 30))),
      now.add(const Duration(minutes: 13)),
    );
    expect(
      UserPresence(
        false,
        now,
      ).nextChangeAt(now.add(const Duration(hours: 2, minutes: 30))),
      now.add(const Duration(hours: 3)),
    );
    expect(
      UserPresence(
        false,
        now,
      ).nextChangeAt(now.add(const Duration(days: 2, hours: 3))),
      now.add(const Duration(days: 3)),
    );
    final expiry = UserPresence(true, now).nextChangeAt(now)!;
    expect(UserPresence(true, now).textAt(expiry), 'Был(а) 1 мин назад');
  });
  test(
    'Typing expiry and future timestamps schedule their next transition',
    () {
      final typing = ChatActivity('typing', now);
      final expiry = typing.nextChangeAt(now)!;
      expect(expiry, now.add(const Duration(seconds: 8)));
      expect(typing.textAt(expiry), isNull);
      expect(typing.nextChangeAt(expiry), isNull);
      expect(ChatActivity('idle', now).nextChangeAt(now), isNull);
      final future = ChatActivity(
        'recording',
        now.add(const Duration(seconds: 20)),
      );
      final start = future.nextChangeAt(now)!;
      expect(future.textAt(start), 'Записывает голосовое…');
      final presence = UserPresence(true, now.add(const Duration(minutes: 2)));
      expect(presence.isOnlineAt(presence.nextChangeAt(now)!), isTrue);
    },
  );
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
