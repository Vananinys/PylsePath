import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/models/chat_message.dart';
import 'package:pulsepath/models/friend_profile.dart';
import 'package:pulsepath/widgets/community_post_share_sheet.dart';

void main() {
  test('post reference survives local serialization and delivery updates', () {
    final message = ChatMessage(
      id: 'm',
      senderId: 'a',
      receiverId: 'b',
      createdAt: DateTime(2026),
      body: 'Публикация сообщества',
      communityPostId: 'post',
    );
    final restored = ChatMessage.fromRow(message.toRow())
        .withDelivery(MessageDelivery.failed);
    expect(restored.communityPostId, 'post');
    expect(restored.photoUrl, isNull);
    expect(restored.routeAttachment, isNull);
  });
  testWidgets(
    'explicit friend selection only, loading retry, duplicate taps and retry id',
    (t) async {
      t.view.physicalSize = const Size(320, 1300);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      var loads = 0, sends = 0;
      final ids = <String>[];
      final sending = Completer<void>();
      await t.pumpWidget(
        MaterialApp(
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: CommunityPostShareSheet(
              postId: 'post',
              currentOwner: () => 'a',
              loadFriends: () async {
                if (++loads == 1) throw StateError('offline');
                return [
                  const FriendProfile(
                    id: 'b',
                    username: 'Друг с длинным именем',
                  ),
                ];
              },
              send: (friend, post, owner, id) async {
                sends++;
                ids.add(id);
                expect([friend, post, owner], ['b', 'post', 'a']);
                await sending.future;
              },
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(sends, 0);
      expect(find.text('Не удалось загрузить друзей'), findsOneWidget);
      await t.tap(find.text('Повторить загрузку'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Друг с длинным именем'));
      await t.tap(find.text('Друг с длинным именем'));
      await t.pump();
      await t.ensureVisible(find.text('Друг с длинным именем'));
      await t.tap(find.text('Друг с длинным именем'));
      await t.pump();
      expect(sends, 1);
      sending.completeError(StateError('offline'));
      await t.pumpAndSettle();
      expect(find.textContaining('Пост может быть недоступен'), findsOneWidget);
      await t.ensureVisible(find.text('Друг с длинным именем'));
      await t.tap(find.text('Друг с длинным именем'));
      await t.pumpAndSettle();
      expect(sends, 2);
      expect(ids.toSet(), hasLength(1));
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('changed account never reveals loaded friends or sends', (
    t,
  ) async {
    var owner = 'a';
    var sends = 0;
    final load = Completer<List<FriendProfile>>();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommunityPostShareSheet(
            postId: 'p',
            currentOwner: () => owner,
            loadFriends: () => load.future,
            send: (a, b, c, d) async {
              sends++;
            },
          ),
        ),
      ),
    );
    owner = 'b';
    load.complete([const FriendProfile(id: 'c', username: 'Private friend')]);
    await t.pumpAndSettle();
    expect(find.text('Private friend'), findsNothing);
    expect(find.textContaining('Аккаунт изменился'), findsOneWidget);
    expect(sends, 0);
  });
}
