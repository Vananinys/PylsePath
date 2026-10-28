import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:pulsepath/models/chat_message.dart';
import 'package:pulsepath/models/video_metadata.dart';
import 'package:pulsepath/services/video_preview_service.dart';
import 'package:pulsepath/widgets/chat_video_player.dart';
import 'package:pulsepath/widgets/video_player_surface.dart';
import 'package:pulsepath/widgets/video_poster.dart';

import 'chat_video_player_test.dart' show FakeVideoPlatform;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VideoPlayerPlatform original;
  late FakeVideoPlatform fake;
  setUp(() {
    original = VideoPlayerPlatform.instance;
    fake = FakeVideoPlatform();
    VideoPlayerPlatform.instance = fake;
  });
  tearDown(() {
    VideoPlayerPlatform.instance = original;
    debugDefaultTargetPlatformOverride = null;
  });
  test('Metadata bounds and cache keep stable private poster reference', () {
    const info = VideoMetadata(
      width: 1080,
      height: 1920,
      durationMs: 65000,
      sizeBytes: 2097152,
    );
    expect(info.durationLabel, '1:05');
    expect(info.sizeLabel, '2.0 МБ');
    expect(videoTime(const Duration(seconds: 3661)), '1:01:01');
    for (final bad in [-1, double.nan, double.infinity, 1.5, '2']) {
      expect(VideoMetadata.tryParse({...info.toJson(), 'width': bad}), isNull);
    }
    expect(
      VideoMetadata.tryParse({...info.toJson(), 'size_bytes': 52428801}),
      isNull,
    );
    final message = ChatMessage.fromRow({
      'id': 'id',
      'video_url': 'https://example.invalid/signed',
      'video_reference': 'chat:owner/video.mp4',
      'video_poster_url': 'https://example.invalid/poster-signed',
      'video_poster_reference': 'chat:owner/chat_poster_id.jpg',
      'video_metadata': info.toJson(),
    });
    final cached = ChatMessage.fromRow(
      message.withDelivery(MessageDelivery.failed).toRow(),
    );
    expect(cached.videoPosterUrl, 'chat:owner/chat_poster_id.jpg');
    expect(cached.videoMetadata!.height, 1920);
    expect(cached.delivery, MessageDelivery.failed);
    expect(
      ChatMessage.fromRow({'video_url': 'chat:old/video.mp4'}).videoMetadata,
      isNull,
    );
  });
  test('Local extraction is cached, bounded, and missing native decoder falls back', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    VideoPreviewService.clearCacheForTesting();
    final folder = await Directory.systemTemp.createTemp('pulsepath-preview-');
    final file = await File('${folder.path}/clip.mp4').writeAsBytes([1, 2, 3]);
    var calls = 0;
    const channel = MethodChannel('pulsepath/video_preview');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          expect(call.method, 'inspect');
          expect(call.arguments['path'], file.path);
          return {
            'width': 640,
            'height': 360,
            'duration_ms': 12000,
            'poster': Uint8List.fromList([1, 2]),
          };
        });
    try {
      final previews = await Future.wait([
        VideoPreviewService.inspect(file.path),
        VideoPreviewService.inspect(file.path),
      ]);
      expect(calls, 1);
      expect(previews.first.metadata.durationLabel, '0:12');
      expect(previews.first.metadata.sizeBytes, 3);
      expect(previews.first.poster, [1, 2]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw PlatformException(code: 'PREVIEW_FAILED'),
          );
      VideoPreviewService.clearCacheForTesting();
      final fallback = await VideoPreviewService.inspect(file.path);
      expect(fallback.poster, isNull);
      expect(fallback.metadata.sizeBytes, 3);
      final large = await File('${folder.path}/large.mp4')
          .open(mode: FileMode.write);
      await large.truncate(52428801);
      await large.close();
      expect(
        (await VideoPreviewService.inspect('${folder.path}/large.mp4')).poster,
        isNull,
      );
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }

  testWidgets(
    'Seek, mute, speed and fullscreen reuse one player and retain position',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ChatVideoPlayer(source: 'https://example.invalid/video.mp4'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Вперёд на 10 секунд'));
      await tester.pump();
      expect(fake.seekPositions.last, const Duration(seconds: 10));
      await tester.tap(find.byTooltip('Назад на 10 секунд'));
      await tester.pump();
      expect(fake.seekPositions.last, Duration.zero);
      await tester.tap(find.byTooltip('Выключить звук'));
      await tester.pump();
      expect(fake.volumes.last, 0);
      await tester.tap(find.byTooltip('Скорость воспроизведения'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5×'));
      await tester.pumpAndSettle();
      final c = tester
          .widget<VideoPlayerSurface>(find.byType(VideoPlayerSurface))
          .controller;
      expect(c.value.playbackSpeed, 1.5);
      await tester.tap(find.byTooltip('Воспроизвести'));
      await tester.pump();
      expect(fake.speeds.last, 1.5);
      await tester.tap(find.byTooltip('Пауза'));
      await tester.pump();
      await c.seekTo(const Duration(seconds: 4));
      await tester.pump();
      await tester.tap(find.byTooltip('На весь экран'));
      await tester.pumpAndSettle();
      expect(fake.created, 1);
      expect(find.byType(VideoPlayerSurface), findsOneWidget);
      expect(
        tester
            .widget<VideoPlayerSurface>(find.byType(VideoPlayerSurface))
            .controller,
        same(c),
      );
      expect(c.value.position, const Duration(seconds: 4));
      await tester.tap(find.byTooltip('Выйти из полного экрана'));
      await tester.pumpAndSettle();
      expect(c.value.position, const Duration(seconds: 4));
      expect(fake.created, 1);
      await close(tester);
      expect(fake.disposed, 1);
    },
  );
  testWidgets(
    'Retry after playback failure refreshes URL and retains position',
    (tester) async {
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ChatVideoPlayer(
            source: 'https://example.invalid/expired.mp4',
            onRefresh: () async =>
                'https://example.invalid/renewed-${++refreshes}.mp4',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final c = tester
          .widget<VideoPlayerSurface>(find.byType(VideoPlayerSurface))
          .controller;
      await c.seekTo(const Duration(seconds: 6));
      await c.setVolume(0);
      await c.setPlaybackSpeed(1.5);
      fake.events[1]!.addError(
        PlatformException(code: '403', message: 'expired'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(refreshes, 1);
      expect(fake.sources.last.uri, contains('renewed-1'));
      expect(fake.seekPositions.last, const Duration(seconds: 6));
      final restored = tester
          .widget<VideoPlayerSurface>(find.byType(VideoPlayerSurface))
          .controller;
      expect(restored.value.volume, 0);
      expect(restored.value.playbackSpeed, 1.5);
      await close(tester);
    },
  );
  testWidgets(
    'Autoplay only after explicit opening; source switch disposes old video',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ChatVideoPlayer(
            source: 'https://example.invalid/a.mp4',
            autoPlay: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(fake.plays, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final played = fake.plays;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(fake.plays, played);
      await tester.pumpWidget(
        const MaterialApp(
          home: ChatVideoPlayer(source: 'https://example.invalid/b.mp4'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(fake.created, 2);
      expect(fake.disposed, 1);
      expect(fake.plays, played);
      await close(tester);
    },
  );
  testWidgets('Portrait poster and player controls fit 320px with 1.6 text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
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
        home: const Scaffold(
          body: Column(
            children: [
              SizedBox(
                width: 220,
                child: VideoPoster(
                  metadata: VideoMetadata(
                    width: 1080,
                    height: 1920,
                    durationMs: 65000,
                  ),
                ),
              ),
              Expanded(
                child: ChatVideoPlayer(
                  source: 'https://example.invalid/portrait.mp4',
                  embedded: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1:05'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Воспроизвести'), findsOneWidget);
    await close(tester);
  });
}
