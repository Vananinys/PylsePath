import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/models/chat_message.dart';
import 'package:pulsepath/data/chat_local_store.dart';
import 'package:pulsepath/services/group_ride_service.dart';
import 'package:pulsepath/widgets/group_invitation_card.dart';

ChatMessage invite({MessageDelivery delivery = MessageDelivery.sent}) =>
    ChatMessage(
      id: 'invite-1',
      senderId: 'owner',
      receiverId: 'friend',
      createdAt: DateTime.utc(2026),
      body: 'Приглашение в совместный заезд: Вечерний круг',
      delivery: delivery,
      groupInvitation: const {
        'id': 'invite-1',
        'title': 'Вечерний круг',
        'organizer': 'Сергей',
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'an invitation survives read receipts and a local cache reload',
    () async {
      SharedPreferences.setMockInitialValues({});
      final read = invite().copyWith(readAt: DateTime.utc(2026, 10, 19));
      final store = ChatLocalStore(
        'owner',
        'friend',
        currentOwner: () => 'owner',
      );
      await store.saveMessages([read]);
      final restored = (await store.readMessages()).single;
      expect(restored.groupInvitation, read.groupInvitation);
      expect(restored.isRead, isTrue);
      expect(restored.isStickerOnly, isFalse);
      expect(restored.senderId, 'owner');
    },
  );
  test('cached invitations do not cross account boundaries', () async {
    SharedPreferences.setMockInitialValues({});
    String owner = 'owner';
    final store = ChatLocalStore('owner', 'friend', currentOwner: () => owner);
    await store.saveMessages([invite()]);
    owner = 'other';
    await expectLater(store.readMessages(), throwsStateError);
    owner = 'owner';
    expect(await store.readMessages(), hasLength(1));
  });
  test(
    'missing timestamps are stale instead of showing a live participant',
    () {
      final member = GroupMember.fromRow({
        'user_id': 'friend',
        'profile': {'username': 'Друг'},
      });
      expect(member.isLive, isFalse);
      expect(member.username, 'Друг');
    },
  );
  testWidgets(
    'invitation card identifies the organizer; pending card cannot be opened',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupInvitationCard(
              message: invite(delivery: MessageDelivery.sending),
            ),
          ),
        ),
      );
      expect(find.text('Вечерний круг'), findsOneWidget);
      expect(find.text('Организатор: Сергей'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: GroupInvitationCard(message: invite())),
        ),
      );
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNotNull,
      );
    },
  );
}
