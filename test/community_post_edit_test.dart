import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/models/community_post.dart';
import 'package:pulsepath/widgets/community_post_card.dart';
import 'package:pulsepath/widgets/community_post_edit_sheet.dart';

CommunityPost post({bool photo = false}) => CommunityPost(
  id: 'post',
  authorId: 'owner',
  authorName: 'Автор',
  body: 'Исходный текст',
  likeCount: 0,
  likedByMe: false,
  createdAt: DateTime(2026),
  audience: CommunityPostAudience.friends,
  privatePhotoPaths: photo ? ['owner/photo.jpg'] : const [],
);
Future<void> open(
  WidgetTester tester, {
  required String? Function() owner,
  required Future<void> Function(String) save,
  CommunityPost? value,
  bool large = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(large ? 2 : 1),
          viewInsets: EdgeInsets.only(bottom: large ? 280 : 0),
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showCommunityPostEditor(
              context,
              post: value ?? post(),
              currentUserId: owner,
              onSave: save,
            ),
            child: const Text('Открыть'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Открыть'));
  await tester.pumpAndSettle();
}

FilledButton saveButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Сохранить'));
void main() {
  testWidgets('editing action exists only for the author', (tester) async {
    for (final owner in ['owner', 'other']) {
      var edited = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommunityPostCard(
              post: post(),
              currentUserId: owner,
              onLike: () {},
              onAuthorTap: () {},
              onEdit: () => edited = true,
            ),
          ),
        ),
      );
      if (owner == 'owner') {
        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Редактировать текст'));
        await tester.pumpAndSettle();
        expect(edited, isTrue);
      } else {
        expect(find.byType(PopupMenuButton<String>), findsNothing);
      }
    }
  });
  testWidgets(
    'successful edit changes only the text and retains attachment/audience',
    (tester) async {
      final original = post(photo: true);
      String? saved;
      await open(
        tester,
        owner: () => 'owner',
        value: original,
        save: (body) async {
          saved = body;
        },
      );
      expect(saveButton(tester).onPressed, isNull);
      expect(find.text('Аудитория: только друзья'), findsOneWidget);
      await tester.enterText(find.byType(TextField), ' Новый текст ');
      await tester.pump();
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(saved, 'Новый текст');
      expect(find.text('Открыть'), findsOneWidget);
      expect(original.body, 'Исходный текст');
      expect(original.privatePhotoPaths, ['owner/photo.jpg']);
      expect(original.audience, CommunityPostAudience.friends);
    },
  );
  testWidgets(
    'failed save retains text and freezes input until the request finishes',
    (tester) async {
      var pending = Completer<void>();
      await open(tester, owner: () => 'owner', save: (_) => pending.future);
      await tester.enterText(find.byType(TextField), 'Не потерять');
      await tester.pump();
      await tester.tap(find.text('Сохранить'));
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      pending.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Не удалось сохранить текст. Проверьте подключение и повторите.',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Не потерять',
      );
      pending = Completer<void>();
      await tester.tap(find.text('Сохранить'));
      await tester.pump();
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('Открыть'), findsOneWidget);
    },
  );
  testWidgets('a switched account never sends edits as the new user', (
    tester,
  ) async {
    String? owner = 'owner';
    var calls = 0;
    await open(
      tester,
      owner: () => owner,
      save: (_) async {
        calls++;
      },
    );
    await tester.enterText(find.byType(TextField), 'Изменённый');
    await tester.pump();
    owner = 'other';
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(
      find.text('Аккаунт изменился. Откройте публикацию заново.'),
      findsOneWidget,
    );
  });
  testWidgets(
    'empty text is allowed only when the post already has an attachment',
    (tester) async {
      await open(tester, owner: () => 'owner', save: (_) async {});
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(saveButton(tester).onPressed, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await open(
        tester,
        owner: () => 'owner',
        value: post(photo: true),
        save: (_) async {},
      );
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(saveButton(tester).onPressed, isNotNull);
    },
  );
  testWidgets('save remains above keyboard at 320px and 200 percent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, owner: () => 'owner', save: (_) async {}, large: true);
    await tester.enterText(find.byType(TextField), 'Новый');
    await tester.pump();
    expect(
      tester.getRect(find.text('Сохранить')).bottom,
      lessThanOrEqualTo(520),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Открыть'), findsOneWidget);
  });
  testWidgets(
    'late save result cannot complete an editor for a different account',
    (tester) async {
      String? owner = 'owner';
      final pending = Completer<void>();
      await open(tester, owner: () => owner, save: (_) => pending.future);
      await tester.enterText(find.byType(TextField), 'Изменённый');
      await tester.pump();
      await tester.tap(find.text('Сохранить'));
      await tester.pump();
      owner = 'other';
      pending.complete();
      await tester.pumpAndSettle();
      expect(
        find.text('Аккаунт изменился. Откройте публикацию заново.'),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.text('Редактировать пост'), findsOneWidget);
    },
  );
  testWidgets(
    'closing dirty text asks before discarding and can continue editing',
    (tester) async {
      await open(tester, owner: () => 'owner', save: (_) async {});
      await tester.enterText(find.byType(TextField), 'Не терять');
      await tester.pump();
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.text('Выйти без сохранения?'), findsOneWidget);
      await tester.tap(find.text('Продолжить'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Не терять',
      );
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Выйти'));
      await tester.pumpAndSettle();
      expect(find.text('Открыть'), findsOneWidget);
    },
  );
}
