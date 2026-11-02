import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/widgets/community_post_card.dart';
import 'package:pulsepath/widgets/community_photo_viewer.dart';
import 'package:pulsepath/models/community_post.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('post actions and expansion at 320px/200% $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var liked = false, comments = false, deleted = false, moderated = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: CommunityPostCard(
                post: CommunityPost(
                  id: 'post',
                  authorId: 'me',
                  authorName: 'Очень длинное имя пользователя',
                  body: List.filled(24, 'Поездка по лесу').join(' '),
                  likeCount: 0,
                  likedByMe: false,
                  createdAt: DateTime(2026),
                ),
                currentUserId: 'me',
                onLike: () => liked = true,
                onAuthorTap: () {},
                onOpenComments: () => comments = true,
                onDelete: () => deleted = true,
                onModerate: () => moderated = true,
              ),
            ),
          ),
        ),
      );
      final like = find.widgetWithText(TextButton, 'Поддержать · 0');
      expect(tester.getSize(like).height, greaterThanOrEqualTo(48));
      await tester.tap(like);
      await tester.tap(find.text('Комментарии · 0'));
      expect(liked && comments, isTrue);
      expect(find.text('Читать полностью'), findsOneWidget);
      await tester.tap(find.text('Читать полностью'));
      await tester.pump();
      expect(find.text('Свернуть'), findsOneWidget);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить пост'));
      await tester.pumpAndSettle();
      expect(deleted, isTrue);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Модерация публикации'));
      await tester.pumpAndSettle();
      expect(moderated, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('failed fullscreen photos can retry and navigate', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CommunityPhotoViewer(
          urls: [
            'https://invalid.example/one.jpg',
            'https://invalid.example/two.jpg',
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Фото 1 из 2'), findsOneWidget);
    expect(find.text('Не удалось загрузить фото'), findsWidgets);
    expect(find.text('Повторить'), findsWidgets);
    await tester.tap(find.byTooltip('Следующее фото'));
    await tester.pumpAndSettle();
    expect(find.text('Фото 2 из 2'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
