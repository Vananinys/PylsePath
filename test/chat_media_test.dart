import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pulsepath/models/chat_media_draft.dart';
import 'package:pulsepath/models/chat_message.dart';
import 'package:pulsepath/widgets/chat_media_composer.dart';
import 'package:pulsepath/widgets/chat_photo_editor.dart';
import 'package:pulsepath/widgets/chat_video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'chat_video_player_test.dart' show FakeVideoPlatform;

import 'package:pulsepath/data/chat_local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatMediaDraft draft(String name, {bool video = false, int size = 1024}) =>
    ChatMediaDraft(file: XFile('/fake/$name'), isVideo: video, size: size);

void main() {
  late VideoPlayerPlatform originalVideo;
  setUp(() {
    originalVideo = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = FakeVideoPlatform();
  });
  tearDown(() {
    VideoPlayerPlatform.instance = originalVideo;
  });
  test('Twenty photos allowed; twenty-one rejected without truncation', () {
    final items = List.generate(20, (i) => draft('$i.jpg'));
    expect(ChatMediaDraft.validateBatch(items), isNull);
    expect(
      ChatMediaDraft.validateBatch([...items, draft('extra.jpg')]),
      contains('20'),
    );
    expect(items.length, 20);
  });
  test('Photo, video and batch byte limits are inclusive', () {
    expect(
      draft('a.jpg', size: ChatMediaDraft.photoLimit).validationError,
      isNull,
    );
    expect(
      draft('a.jpg', size: ChatMediaDraft.photoLimit + 1).validationError,
      isNotNull,
    );
    expect(
      draft(
        'a.mp4',
        video: true,
        size: ChatMediaDraft.videoLimit,
      ).validationError,
      isNull,
    );
    expect(
      draft(
        'a.mp4',
        video: true,
        size: ChatMediaDraft.videoLimit + 1,
      ).validationError,
      isNotNull,
    );
    final video = draft('a.mov', video: true, size: ChatMediaDraft.videoLimit);
    expect(ChatMediaDraft.validateBatch([video, video]), isNull);
    expect(
      ChatMediaDraft.validateBatch([video, video, draft('a.jpg')]),
      contains('100'),
    );
  });
  test('Empty, unsupported and mismatched media rejected', () {
    expect(ChatMediaDraft.validateBatch([]), isNotNull);
    expect(draft('a.jpg', size: 0).validationError, isNotNull);
    expect(draft('a.gif').validationError, isNotNull);
    expect(draft('a.exe', video: true).validationError, isNotNull);
    expect(draft('a.jpg', video: true).validationError, isNotNull);
    expect(draft('A.WEBM', video: true).validationError, isNull);
  });
  test('Edited bytes use PNG and actual edited size, retaining original', () {
    final original = draft('a.jpg', size: 123);
    final edited = original.edited(Uint8List(456));
    expect(original.editedBytes, isNull);
    expect(original.byteLength, 123);
    expect(edited.extension, '.png');
    expect(edited.byteLength, 456);
  });
  test('Video signed URL and persistent reference survive copying', () {
    final message = ChatMessage.fromRow({
      'id': 'm',
      'sender_id': 'a',
      'receiver_id': 'b',
      'video_url': 'https://example.invalid/video',
      'video_reference': 'chat:a/chat_video_m.mp4',
      'created_at': '2026-10-26T00:00:00Z',
    });
    expect(message.isVideo, isTrue);
    expect(message.isPhoto, isFalse);
    expect(
      message.copyWith(delivery: MessageDelivery.failed).videoUrl,
      message.videoUrl,
    );
    expect(message.toRow()['video_url'], 'chat:a/chat_video_m.mp4');
    expect(ChatMessage.fromRow(message.toRow()).isVideo, isTrue);
  });
  test('Old text and photo rows remain readable', () {
    expect(ChatMessage.fromRow({'body': 'hello'}).isVideo, isFalse);
    expect(
      ChatMessage.fromRow({'photo_url': 'chat:a/photo.jpg'}).isPhoto,
      isTrue,
    );
  });
  test(
    'Pending videos restored as failed, scoped to the original account',
    () async {
      SharedPreferences.setMockInitialValues({});
      String? owner = 'alice';
      final store = ChatLocalStore(owner, 'bob', currentOwner: () => owner);
      await store.saveMessages([
        ChatMessage(
          id: 'v',
          senderId: 'alice',
          receiverId: 'bob',
          videoUrl: '/private/video.mp4',
          delivery: MessageDelivery.sending,
          createdAt: DateTime.utc(2026, 10, 26),
        ),
      ]);
      final loaded = await store.readMessages();
      expect(loaded.single.videoUrl, '/private/video.mp4');
      expect(loaded.single.delivery, MessageDelivery.failed);
      owner = 'other';
      expect(await store.readMessages(), isEmpty);
    },
  );

  Future<Uint8List> imageBytes(WidgetTester tester) async {
    final result = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 4, 4),
        Paint()..color = const Color(0xFFFF0000),
      );
      canvas.drawRect(
        const Rect.fromLTWH(4, 0, 4, 4),
        Paint()..color = const Color(0xFF0000FF),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(8, 4);
      try {
        return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
            .asUint8List();
      } finally {
        image.dispose();
        picture.dispose();
      }
    });
    return result!;
  }

  testWidgets('Crop and quarter rotation change actual pixels and dimensions', (
    tester,
  ) async {
    final bytes = await imageBytes(tester);
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(bytes);
      final input = (await codec.getNextFrame()).image;
      try {
        final result = await renderChatPhoto(
          input,
          1,
          const Rect.fromLTWH(0, 0, 1, .5),
        );
        final outputCodec = await ui.instantiateImageCodec(result);
        final output = (await outputCodec.getNextFrame()).image;
        try {
          expect(output.width, 4);
          expect(output.height, 4);
          final pixels = (await output.toByteData())!.buffer.asUint8List();
          expect(pixels[0], 255);
          expect(pixels[2], 0); // Red half, not a visual-only transform.
        } finally {
          output.dispose();
          outputCodec.dispose();
        }
      } finally {
        input.dispose();
        codec.dispose();
      }
    });
  });
  testWidgets('Empty crop rejected without modifying source', (tester) async {
    final bytes = await imageBytes(tester);
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(bytes);
      final input = (await codec.getNextFrame()).image;
      try {
        await expectLater(
          renderChatPhoto(input, 0, Rect.zero),
          throwsFormatException,
        );
        expect(input.width, 8);
      } finally {
        input.dispose();
        codec.dispose();
      }
    });
  });

  Future<void> composer(
    WidgetTester tester,
    List<ChatMediaDraft> items, {
    ValueChanged<List<ChatMediaDraft>?>? onResult,
    Future<List<ChatMediaDraft>> Function()? add,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final result = await Navigator.push<List<ChatMediaDraft>>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatMediaComposer(
                      items: items,
                      onAddPhotos: add ?? () async => [],
                      onAddVideo: () async => [],
                    ),
                  ),
                );
                onResult?.call(result);
              },
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
  }

  testWidgets('Selection is previewed and only confirmed send returns it', (
    tester,
  ) async {
    List<ChatMediaDraft>? sent;
    final a = draft('first.mp4', video: true);
    await composer(tester, [
      a,
      draft('second.mov', video: true),
    ], onResult: (v) => sent = v);
    expect(sent, isNull);
    expect(find.byType(ChatVideoPlayer), findsOneWidget);
    expect(find.byTooltip('Воспроизвести'), findsOneWidget);
    await tester.tap(find.text('Убрать'));
    await tester.pumpAndSettle();
    expect(find.text('Отправить 1'), findsOneWidget);
    await tester.tap(find.text('Отправить 1'));
    await tester.pumpAndSettle();
    expect(sent!.single.file.path, '/fake/second.mov');
  });
  testWidgets('Back cancels without sending', (tester) async {
    bool returned = false;
    List<ChatMediaDraft>? sent;
    await composer(
      tester,
      [draft('a.mp4', video: true)],
      onResult: (value) {
        returned = true;
        sent = value;
      },
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(sent, isNull);
  });
  testWidgets('Add does not silently truncate an oversized selection', (
    tester,
  ) async {
    await composer(
      tester,
      List.generate(19, (i) => draft('$i.mp4', video: true)),
      add: () async => [draft('new.jpg'), draft('extra.jpg')],
    );
    await tester.tap(find.text('Ещё фото'));
    await tester.pumpAndSettle();
    expect(find.text('Можно отправить до 20 файлов за раз'), findsOneWidget);
    expect(find.text('Вложения · 19/20'), findsOneWidget);
  });
  testWidgets('320px with large text still allows sending and removing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: ChatMediaComposer(
          items: [draft('a.mp4', video: true)],
          onAddPhotos: () async => [],
          onAddVideo: () async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Отправить 1'), findsOneWidget);
    await tester.tap(find.text('Убрать'));
    await tester.pumpAndSettle();
    expect(find.text('Добавьте фото или видео'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
