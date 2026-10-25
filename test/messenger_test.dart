import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/chat_local_store.dart';
import 'package:pulsepath/models/chat_message.dart';
import 'package:pulsepath/models/shared_route.dart';
import 'package:pulsepath/models/friend_profile.dart';
import 'package:pulsepath/screens/chat_screen.dart';
import 'package:pulsepath/services/chat_service.dart';
import 'package:pulsepath/widgets/map_sticker_flight.dart';

ChatMessage message(
  String id, {
  String? body,
  MessageDelivery delivery = MessageDelivery.sent,
}) => ChatMessage(
  id: id,
  senderId: 'me',
  receiverId: 'friend',
  body: body ?? 'Сообщение $id',
  createdAt: DateTime.utc(2026, 10, 17, 10),
  delivery: delivery,
);

class FakeChat extends ChatService {
  FakeChat() : super.forTesting() {
    connected.value = true;
  }
  @override
  String? get userId => 'me';
  bool failSend = false;
  bool failLoad = false;
  final List<String?> sentIds = [];
  List<ChatMessage> page = [];
  List<ChatMessage> olderPage = [];
  int fetchCalls = 0;
  ChatMessage? lastBefore;
  final List<void Function(ChatMessage)> callbacks = [];
  @override
  Future<void> subscribe(void Function(ChatMessage) listener) async {
    callbacks.add(listener);
  }

  @override
  void unsubscribe(void Function(ChatMessage) listener) {
    callbacks.remove(listener);
  }

  @override
  Future<List<ChatMessage>> fetchConversation(
    String friendId, {
    int limit = 60,
    ChatMessage? before,
    String? search,
    bool strict = false,
  }) async {
    fetchCalls++;
    lastBefore = before;
    if (failLoad) throw const ChatServiceException('Нет сети');
    if (before != null) return olderPage;
    return page
        .where((m) => search == null || (m.body?.contains(search) ?? false))
        .toList();
  }

  @override
  Future<Map<String, ChatMessage>> fetchReplyTargets(
    Iterable<ChatMessage> messages,
  ) async => {};
  @override
  Future<bool> markRead(String friendId) async => true;
  @override
  Future<void> refreshUnread() async {}
  @override
  Future<bool> toggleReaction(String messageId, String emoji, bool add) async {
    final original = page.firstWhere((message) => message.id == messageId);
    final updated = ChatMessage.fromRow({
      ...original.toRow(),
      'reactions': {
        emoji: add ? ['me'] : <String>[],
      },
    });
    for (final callback in List.of(callbacks)) {
      callback(updated);
    }
    return true;
  }

  @override
  Future<({bool byMe, bool byThem})> blockState(String friendId) async =>
      (byMe: false, byThem: false);
  @override
  Future<ChatMessage?> sendMessage(
    String receiverId, {
    String? text,
    String? sticker,
    String? photoPath,
    String? audioPath,
    int? audioSeconds,
    String? replyToId,
    String? messageId,
    bool retry = false,
    SharedRoute? routeAttachment,
  }) async {
    sentIds.add(messageId);
    if (failSend) throw const ChatServiceException('Нет сети');
    return message(messageId!, body: text);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final windows = Platform.environment['WINDIR'];
    if (windows != null) {
      final file = File('$windows/Fonts/arial.ttf');
      if (await file.exists()) {
        final font = FontLoader('Roboto')
          ..addFont(
            Future.value(ByteData.sublistView(await file.readAsBytes())),
          );
        await font.load();
      }
    }
    final icons = File(
      'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
    );
    if (await icons.exists()) {
      final font = FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.sublistView(await icons.readAsBytes())));
      await font.load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global/events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (_) async => null,
    );
  });

  test(
    'Pending messages survive reopening and become explicitly retryable',
    () async {
      final store = ChatLocalStore('me', 'friend', currentOwner: () => 'me');
      await store.saveMessages([
        message('stable-id', delivery: MessageDelivery.sending),
      ]);
      final reopened = ChatLocalStore('me', 'friend', currentOwner: () => 'me');
      final rows = await reopened.readMessages();
      expect(rows.single.id, 'stable-id');
      expect(rows.single.delivery, MessageDelivery.failed);
      expect(
        await ChatLocalStore(
          'another',
          'friend',
          currentOwner: () => 'another',
        ).readMessages(),
        isEmpty,
      );
    },
  );

  test('Draft writes preserve order and clearing removes old text', () async {
    final store = ChatLocalStore('me', 'friend', currentOwner: () => 'me');
    final first = store.saveDraft('Старый текст');
    final second = store.saveDraft('');
    await Future.wait([first, second]);
    expect(await store.readDraft(), '');
  });

  test(
    'Private signed URLs are replaced by stable storage references in cache',
    () async {
      final original = ChatMessage(
        id: 'photo',
        senderId: 'me',
        receiverId: 'friend',
        createdAt: DateTime.now(),
        photoUrl: 'https://example.com/signed?token=secret',
        photoReference: 'chat:me/photo.jpg',
      );
      final store = ChatLocalStore('me', 'friend', currentOwner: () => 'me');
      await store.saveMessages([original]);
      expect((await store.readMessages()).single.photoUrl, 'chat:me/photo.jpg');
      expect(
        original.withDelivery(MessageDelivery.failed).photoUrl,
        original.photoUrl,
      );
    },
  );

  testWidgets('Failed send stays visible and retry uses the exact same id', (
    tester,
  ) async {
    final chat = FakeChat()..failSend = true;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          friend: const FriendProfile(id: 'friend', username: 'Сергей'),
          service: chat,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Поехали кататься');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(find.text('Поехали кататься'), findsOneWidget);
    expect(find.text('Не отправлено · повторить'), findsOneWidget);
    chat.failSend = false;
    await tester.tap(find.text('Не отправлено · повторить'));
    await tester.pumpAndSettle();
    expect(chat.sentIds.length, 2);
    expect(chat.sentIds[0], chat.sentIds[1]);
    expect(find.text('Не отправлено · повторить'), findsNothing);
    expect(find.text('Поехали кататься'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Load errors offer retry instead of pretending history is empty',
    (tester) async {
      final chat = FakeChat()..failLoad = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            friend: const FriendProfile(id: 'friend', username: 'Сергей'),
            service: chat,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Нет сети'), findsOneWidget);
      expect(find.text('Повторить'), findsOneWidget);
      chat
        ..failLoad = false
        ..page = [message('server-id', body: 'История восстановлена')];
      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(find.text('История восстановлена'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Sticker single and rain animations stay valid and reach the avatar',
    (tester) async {
      const start = Offset(100, 600);
      const end = Offset(200, 180);
      expect(StickerFlight.position(start, end, 0), start);
      expect(
        (StickerFlight.position(start, end, 1) - end).distance,
        lessThan(.001),
      );
      for (final rain in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Stack(
              children: [
                StickerFlight(
                  key: ValueKey(rain),
                  emoji: '❤️',
                  from: start,
                  to: end,
                  rain: rain,
                ),
              ],
            ),
          ),
        );
        for (var i = 0; i < 25; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Reaction updates preserve history without a full refetch', (
    tester,
  ) async {
    final chat = FakeChat()..page = [message('react', body: 'Поставь реакцию')];
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          friend: const FriendProfile(id: 'friend', username: 'Сергей'),
          service: chat,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = chat.fetchCalls;
    await tester.longPress(find.text('Поставь реакцию'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('👍'));
    await tester.pumpAndSettle();
    expect(chat.fetchCalls, before);
    expect(find.text('Поставь реакцию'), findsOneWidget);
    expect(find.text('👍'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('Older pages load and incoming messages do not jump to bottom', (
    tester,
  ) async {
    final chat = FakeChat()
      ..page = List.generate(
        60,
        (i) => ChatMessage(
          id: 'page_$i',
          senderId: 'me',
          receiverId: 'friend',
          body: 'Сообщение $i',
          createdAt: DateTime.utc(2026, 10, 17, 10, i),
        ),
      );
    chat.olderPage = [
      ChatMessage(
        id: 'older',
        senderId: 'me',
        receiverId: 'friend',
        body: 'Более старое сообщение',
        createdAt: DateTime.utc(2026, 10, 16),
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          friend: const FriendProfile(id: 'friend', username: 'Сергей'),
          service: chat,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<ListView>(find.byType(ListView).first)
        .controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(chat.lastBefore?.id, 'page_0');
    expect(controller.offset, greaterThan(300));
    final incoming = ChatMessage(
      id: 'incoming-new',
      senderId: 'friend',
      receiverId: 'me',
      body: 'Новое сообщение внизу',
      createdAt: DateTime.now(),
    );
    for (final callback in List.of(chat.callbacks)) {
      callback(incoming);
    }
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(300));
    expect(find.text('1 ↓'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('Chat fits a narrow phone and captures the actual layout', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final chat = FakeChat()
      ..page = [
        ChatMessage(
          id: 'incoming',
          senderId: 'friend',
          receiverId: 'me',
          body: 'Привет! Поедем сегодня кататься? 🚴',
          createdAt: DateTime.now().subtract(const Duration(minutes: 3)),
        ),
        ChatMessage(
          id: 'outgoing',
          senderId: 'me',
          receiverId: 'friend',
          body: 'Да! Встречаемся у парка в 18:00',
          createdAt: DateTime.now(),
          readAt: DateTime.now(),
        ),
      ];
    const previewKey = Key('chat-preview');
    await tester.pumpWidget(
      RepaintBoundary(
        key: previewKey,
        child: MaterialApp(
          home: ChatScreen(
            friend: const FriendProfile(id: 'friend', username: 'Александр'),
            service: chat,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(previewKey),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/qa').create(recursive: true);
      await File('build/qa/chat_messenger.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
