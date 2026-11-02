import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/screens/post_comments_screen.dart';
import 'package:pulsepath/models/community_post.dart';
import 'package:pulsepath/models/post_comment.dart';
import 'package:pulsepath/services/community_service.dart';

class FakeCommunity extends CommunityService {
  String? owner = 'first';
  @override
  String? get userId => owner;
  Completer<void>? sending;
  Completer<List<PostComment>>? loading;
  bool offline = false;
  bool photoUnavailable = false;
  int fetches = 0;
  String? sentReply;
  @override
  Future<List<PostComment>> fetchComments(
    String postId, {
    bool strict = false,
  }) async {
    fetches++;
    if (loading != null) return loading!.future;
    if (offline) throw const CommunityServiceException('Нет сети');
    return [
      PostComment(
        id: 'comment',
        postId: 'post',
        authorId: 'friend',
        authorName: 'Друг',
        body: 'Первый комментарий',
        photoUrl: photoUnavailable
            ? 'https://photo.example.invalid/expired.jpg'
            : null,
        privatePhotoPath: photoUnavailable ? 'friend/expired.jpg' : null,
        createdAt: DateTime(2026),
      ),
    ];
  }

  @override
  Future<void> addComment(
    String postId, {
    String? body,
    String? parentCommentId,
    String? photoPath,
    String? expectedOwner,
  }) async {
    sentReply = parentCommentId;
    await sending?.future;
  }
}

CommunityPost post() => CommunityPost(
  id: 'post',
  authorId: 'friend',
  authorName: 'Друг',
  body: 'Пост',
  likeCount: 0,
  likedByMe: false,
  createdAt: DateTime(2026),
);
Widget screen(FakeCommunity service, {bool large = false}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(large ? 2 : 1),
      viewInsets: EdgeInsets.only(bottom: large ? 280 : 0),
    ),
    child: child!,
  ),
  home: PostCommentsScreen(post: post(), service: service),
);
Finder button(String tip) =>
    find.byWidgetPredicate((w) => w is IconButton && w.tooltip == tip);
void main() {
  testWidgets(
    'sending freezes reply and text; failure retains draft for retry',
    (tester) async {
      final service = FakeCommunity()..sending = Completer<void>();
      await tester.pumpWidget(screen(service));
      await tester.pumpAndSettle();
      expect(
        tester.widget<IconButton>(button('Отправить комментарий')).onPressed,
        isNull,
      );
      await tester.tap(find.text('Ответить'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Ответ другу');
      await tester.pump();
      await tester.tap(button('Отправить комментарий'));
      await tester.pump();
      expect(service.sentReply, 'comment');
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(
        tester.widget<IconButton>(button('Отменить ответ')).onPressed,
        isNull,
      );
      expect(
        tester.widget<IconButton>(button('Прикрепить фото')).onPressed,
        isNull,
      );
      service.sending!.completeError(
        const CommunityServiceException('Ошибка отправки'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ответ другу'), findsOneWidget);
      expect(find.text('Ответ Друг'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .hideCurrentSnackBar();
      await tester.pumpAndSettle();
      service.sending = Completer<void>();
      await tester.tap(button('Отправить комментарий'));
      await tester.pump();
      service.sending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Ответ другу'), findsNothing);
      expect(find.text('Ответ Друг'), findsNothing);
      expect(
        tester.widget<IconButton>(button('Отправить комментарий')).onPressed,
        isNull,
      );
    },
  );
  testWidgets('late refresh cannot replace newer comments', (tester) async {
    final service = FakeCommunity()..offline = true;
    await tester.pumpWidget(screen(service));
    await tester.pumpAndSettle();
    final old = Completer<List<PostComment>>();
    service.loading = old;
    await tester.tap(find.text('Повторить загрузку'));
    await tester.pump();
    final newer = Completer<List<PostComment>>();
    service.loading = newer;
    await tester.tap(find.text('Повторить загрузку'));
    await tester.pump();
    newer.complete([
      PostComment(
        id: 'new',
        postId: 'post',
        authorId: 'friend',
        authorName: 'Друг',
        body: 'Свежий ответ',
        createdAt: DateTime(2026),
      ),
    ]);
    await tester.pumpAndSettle();
    old.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('Свежий ответ'), findsOneWidget);
    expect(find.text('Комментариев пока нет'), findsNothing);
  });
  testWidgets('late load from previous account is hidden', (tester) async {
    final service = FakeCommunity()..loading = Completer<List<PostComment>>();
    await tester.pumpWidget(screen(service));
    await tester.pump();
    service.owner = 'second';
    service.loading!.complete([]);
    await tester.pumpAndSettle();
    expect(
      find.text('Аккаунт изменился. Откройте комментарии заново.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
  });
  testWidgets(
    'offline error is distinct from empty and works with keyboard at 320px and 200%',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = FakeCommunity()..offline = true;
      await tester.pumpWidget(screen(service, large: true));
      await tester.pumpAndSettle();
      expect(find.text('Комментариев пока нет'), findsNothing);
      expect(find.text('Повторить загрузку'), findsOneWidget);
      service.offline = false;
      await tester.tap(find.text('Повторить загрузку'));
      await tester.pumpAndSettle();
      expect(find.text('Первый комментарий'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('failed private photo exposes retry and reloads signed media', (
    tester,
  ) async {
    final service = FakeCommunity()..photoUnavailable = true;
    await tester.pumpWidget(screen(service));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Фото недоступно'), findsOneWidget);
    final before = service.fetches;
    service.photoUnavailable = false;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(service.fetches, greaterThan(before));
    expect(find.text('Фото недоступно'), findsNothing);
    expect(find.text('Первый комментарий'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
