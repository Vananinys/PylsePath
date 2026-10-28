import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/utils/chat_media_files.dart';
import 'package:pulsepath/data/chat_local_store.dart';
import 'package:pulsepath/models/chat_message.dart';
import 'package:pulsepath/widgets/chat_photo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Retained voice and pending queue survive a replaced temporary recording',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pulsepath-retained-voice-',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => directory.path,
      );
      SharedPreferences.setMockInitialValues({});
      try {
        final source = File('${directory.path}/temporary.m4a');
        await source.writeAsBytes([1, 2, 3, 4]);
        final retained = await retainChatMedia(
          XFile(source.path),
          'owner',
          'message',
          '.m4a',
        );
        final store = ChatLocalStore(
          'owner',
          'friend',
          currentOwner: () => 'owner',
        );
        await store.saveMessages([
          ChatMessage(
            id: 'message',
            senderId: 'owner',
            receiverId: 'friend',
            audioUrl: retained,
            audioSeconds: 3,
            createdAt: DateTime.utc(2026),
            delivery: MessageDelivery.sending,
          ),
        ]);
        await source.writeAsBytes([9]);
        final restored = await ChatLocalStore(
          'owner',
          'friend',
          currentOwner: () => 'owner',
        ).readMessages();
        expect(restored.single.delivery, MessageDelivery.failed);
        expect(restored.single.audioUrl, contains('chat_pending'));
        expect(await File(restored.single.audioUrl!).readAsBytes(), [
          1,
          2,
          3,
          4,
        ]);
        expect(
          await ChatLocalStore(
            'other',
            'friend',
            currentOwner: () => 'other',
          ).readMessages(),
          isEmpty,
        );
      } finally {
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
      }
    },
  );

  test('Local cleanup deletes only exact retained files of the chosen owner/message', () async {
    final dir = await Directory.systemTemp.createTemp(
      'pulsepath-cleanup-boundary-',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => dir.path,
    );
    try {
      final folder = await Directory('${dir.path}/chat_pending/owner')
          .create(recursive: true);
      final chosen = await File('${folder.path}/message.m4a').writeAsBytes([1]);
      final poster = await File('${folder.path}/poster-message.jpg')
          .writeAsBytes([2]);
      final unrelated = await File('${folder.path}/different.m4a')
          .writeAsBytes([3]);
      final outside = await File('${dir.path}/message.m4a').writeAsBytes([4]);
      await removeRetainedChatMedia('owner', 'message', [
        outside.path,
      ], isCurrent: () => true);
      expect(await chosen.exists(), isFalse);
      expect(await poster.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
      expect(await outside.exists(), isTrue);
    } finally {
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
    }
  });
  testWidgets(
    'Chat previews decode at display resolution while fullscreen keeps zoom detail',
    (tester) async {
      const source = 'https://example.invalid/preview.png';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPhoto(source: source, onRetry: () async {}),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        isA<ResizeImage>(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPhoto(
              source: source,
              fullScreen: true,
              onRetry: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        isNot(isA<ResizeImage>()),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
