import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/screens/profile_customize_screen.dart';
import 'package:pulsepath/services/achievement_journey.dart';
import 'package:pulsepath/services/profile_presentation_service.dart';
import 'package:pulsepath/widgets/profile_identity_card.dart';
import 'package:pulsepath/widgets/settings_hub.dart';
import 'package:pulsepath/screens/profile_cover_editor.dart';
import 'package:pulsepath/models/profile_cover_crop.dart';
import 'package:pulsepath/ui/app_theme.dart';

void main() {
  testWidgets(
    'opening from the profile banner goes straight to banner controls',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileCustomizeScreen(
            initial: const ProfilePresentation(),
            name: 'Райдер',
            avatar: const CircleAvatar(child: Icon(Icons.person)),
            availableRanks: JourneyRank.all.take(1).toList(),
            initialSection: 'cover',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Баннер профиля'), findsOneWidget);
      expect(find.text('Выбрать фотографию'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'the overlapping top of the avatar edits the avatar, not the banner',
    (tester) async {
      var avatarTaps = 0, coverTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: ProfileIdentityCard(
                name: 'Райдер',
                avatar: const CircleAvatar(
                  radius: 48,
                  child: Icon(Icons.person),
                ),
                style: const ProfilePresentation(),
                onEditAvatar: () => avatarTaps++,
                onEditCover: () => coverTaps++,
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byKey(const Key('profile-avatar-edit')));
      await tester.tapAt(Offset(rect.center.dx, rect.top + 16));
      await tester.pump();
      expect(avatarTaps, 1);
      expect(coverTaps, 0);
    },
  );
  const initial = ProfilePresentation(
    accent: 'forest',
    cover: 'contour',
    frame: 'plain',
  );
  Widget editor() => MaterialApp(
    home: ProfileCustomizeScreen(
      initial: initial,
      name: 'Райдер',
      avatar: const CircleAvatar(child: Icon(Icons.person)),
      availableRanks: JourneyRank.all.take(3).toList(),
    ),
  );
  testWidgets('trying an optional look never applies it on dismissal', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(editor());
    await tester.scrollUntilVisible(
      find.text('Идеи'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Идеи'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Тёплый маршрут'));
    await tester.tap(find.text('Тёплый маршрут'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Оставить мой вариант'));
    await tester.tap(find.text('Оставить мой вариант'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(ProfileIdentityCard),
      -160,
      scrollable: find.byType(Scrollable).first,
    );
    final profile = tester.widget<ProfileIdentityCard>(
      find.byType(ProfileIdentityCard),
    );
    expect(profile.style.accent, 'forest');
    expect(profile.style.frame, 'plain');
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Сохранить изменения'),
          )
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'banner is directly editable and crop choice is only offered for photos',
    (tester) async {
      await tester.pumpWidget(editor());
      await tester.tap(find.text('Баннер'));
      await tester.pumpAndSettle();
      expect(find.text('Выбрать фотографию'), findsOneWidget);
      expect(find.text('Цвет и узор'), findsOneWidget);
      expect(find.text('Расположить фотографию'), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('settings are grouped and back returns to categories', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsHub(
          summaries: const {
            'Внешний вид': 'Модули',
            'Приватность': 'Кто видит вас',
          },
          children: [
            const SettingsSectionHeading('Внешний вид'),
            const Text('Разделы приложения'),
            const SettingsSectionHeading('Приватность'),
            SwitchListTile(
              title: const Text('Позиция друзьям'),
              value: false,
              onChanged: (_) {},
            ),
          ],
        ),
      ),
    );
    expect(find.text('Позиция друзьям'), findsNothing);
    await tester.tap(find.text('Приватность'));
    await tester.pumpAndSettle();
    expect(find.text('Позиция друзьям'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Настройте под себя'), findsOneWidget);
  });
  testWidgets(
    'photo position is applied explicitly and cancel keeps the saved crop',
    (tester) async {
      final bytes = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 900, 600),
          Paint()..color = Colors.blue,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(900, 600);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        return data!.buffer.asUint8List();
      });
      final image = MemoryImage(bytes!);
      var accepted = const ProfileCoverCrop();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  final result = await Navigator.push<ProfileCoverCrop>(
                    c,
                    MaterialPageRoute(
                      builder: (_) =>
                          ProfileCoverEditor(image: image, initial: accepted),
                    ),
                  );
                  if (result != null) accepted = result;
                },
                child: const Text('Открыть кадр'),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(image, tester.element(find.byType(Scaffold))),
      );
      await tester.tap(find.text('Открыть кадр'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('cover-crop-gesture')),
        const Offset(0, -50),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Применить'));
      await tester.pumpAndSettle();
      expect(accepted, isNot(const ProfileCoverCrop()));
      final saved = accepted;
      await tester.tap(find.text('Открыть кадр'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('cover-crop-gesture')),
        const Offset(0, 40),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(accepted, saved);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('profile fits a narrow phone with large text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: ProfileCustomizeScreen(
            initial: initial,
            name: 'Очень длинное имя пользователя',
            avatar: const CircleAvatar(child: Icon(Icons.person)),
            availableRanks: JourneyRank.all.take(3).toList(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'progress starts at the real value and reduced motion skips transitions',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: AppProgressIndicator(value: .7)),
        ),
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .7,
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(body: AppProgressIndicator(value: .3)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .3,
      );
    },
  );
}
